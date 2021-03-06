{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PatternGuards #-}
-- | A sqlite backend for persistent.
--
-- Note: If you prepend @WAL=off @ to your connection string, it will disable
-- the write-ahead log. This functionality is now deprecated in favour of using SqliteConnectionInfo.
module Database.Persist.Sqlite
    ( withSqlitePool
    , withSqlitePoolInfo
    , withSqliteConn
    , withSqliteConnInfo
    , createSqlitePool
    , createSqlitePoolFromInfo
    , module Database.Persist.Sql
    , SqliteConf (..)
    , SqliteConnectionInfo
    , mkSqliteConnectionInfo
    , sqlConnectionStr
    , walEnabled
    , fkEnabled
    , extraPragmas
    , runSqlite
    , runSqliteInfo
    , wrapConnection
    , wrapConnectionInfo
    , mockMigration
    ) where

import Database.Persist.Sql
import Database.Persist.Sql.Types.Internal (mkPersistBackend)
import qualified Database.Persist.Sql.Util as Util

import qualified Database.Sqlite as Sqlite

import Control.Applicative as A
import qualified Control.Exception as E
import Control.Monad (forM_)
import Control.Monad.IO.Unlift (MonadIO (..), MonadUnliftIO, withUnliftIO, unliftIO)
import Control.Monad.Logger (NoLoggingT, runNoLoggingT, MonadLogger)
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import UnliftIO.Resource (ResourceT, runResourceT)
import Control.Monad.Trans.Writer (runWriterT)
import Data.Acquire (Acquire, mkAcquire, with)
import Data.Aeson
import Data.Aeson.Types (modifyFailure)
import Data.Conduit
import qualified Data.Conduit.List as CL
import qualified Data.HashMap.Lazy as HashMap
import Data.Int (Int64)
import Data.IORef
import qualified Data.Map as Map
import Data.Monoid ((<>))
import Data.Pool (Pool)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Lens.Micro.TH (makeLenses)

-- | Create a pool of SQLite connections.
--
-- Note that this should not be used with the @:memory:@ connection string, as
-- the pool will regularly remove connections, destroying your database.
-- Instead, use 'withSqliteConn'.
createSqlitePool :: (MonadLogger m, MonadUnliftIO m, IsSqlBackend backend)
                 => Text -> Int -> m (Pool backend)
createSqlitePool = createSqlitePoolFromInfo . conStringToInfo

-- | Create a pool of SQLite connections.
--
-- Note that this should not be used with the @:memory:@ connection string, as
-- the pool will regularly remove connections, destroying your database.
-- Instead, use 'withSqliteConn'.
--
-- @since 2.6.2
createSqlitePoolFromInfo :: (MonadLogger m, MonadUnliftIO m, IsSqlBackend backend)
                         => SqliteConnectionInfo -> Int -> m (Pool backend)
createSqlitePoolFromInfo connInfo = createSqlPool $ open' connInfo

-- | Run the given action with a connection pool.
--
-- Like 'createSqlitePool', this should not be used with @:memory:@.
withSqlitePool :: (MonadUnliftIO m, MonadLogger m, IsSqlBackend backend)
               => Text
               -> Int -- ^ number of connections to open
               -> (Pool backend -> m a) -> m a
withSqlitePool connInfo = withSqlPool . open' $ conStringToInfo connInfo

-- | Run the given action with a connection pool.
--
-- Like 'createSqlitePool', this should not be used with @:memory:@.
--
-- @since 2.6.2
withSqlitePoolInfo :: (MonadUnliftIO m, MonadLogger m, IsSqlBackend backend)
               => SqliteConnectionInfo
               -> Int -- ^ number of connections to open
               -> (Pool backend -> m a) -> m a
withSqlitePoolInfo connInfo = withSqlPool $ open' connInfo

withSqliteConn :: (MonadUnliftIO m, MonadLogger m, IsSqlBackend backend)
               => Text -> (backend -> m a) -> m a
withSqliteConn = withSqliteConnInfo . conStringToInfo

-- | @since 2.6.2
withSqliteConnInfo :: (MonadUnliftIO m, MonadLogger m, IsSqlBackend backend)
                   => SqliteConnectionInfo -> (backend -> m a) -> m a
withSqliteConnInfo = withSqlConn . open'

open' :: (IsSqlBackend backend) => SqliteConnectionInfo -> LogFunc -> IO backend
open' connInfo logFunc = do
    conn <- Sqlite.open $ _sqlConnectionStr connInfo
    wrapConnectionInfo connInfo conn logFunc `E.onException` Sqlite.close conn

-- | Wrap up a raw 'Sqlite.Connection' as a Persistent SQL 'Connection'.
--
-- @since 1.1.5
wrapConnection :: (IsSqlBackend backend) => Sqlite.Connection -> LogFunc -> IO backend
wrapConnection = wrapConnectionInfo (mkSqliteConnectionInfo "")

-- | Wrap up a raw 'Sqlite.Connection' as a Persistent SQL
-- 'Connection', allowing full control over WAL and FK constraints.
--
-- @since 2.6.2
wrapConnectionInfo :: (IsSqlBackend backend)
                  => SqliteConnectionInfo
                  -> Sqlite.Connection
                  -> LogFunc
                  -> IO backend
wrapConnectionInfo connInfo conn logFunc = do
    let
        -- Turn on the write-ahead log
        -- https://github.com/yesodweb/persistent/issues/363
        walPragma
          | _walEnabled connInfo = ("PRAGMA journal_mode=WAL;":)
          | otherwise = id

        -- Turn on foreign key constraints
        -- https://github.com/yesodweb/persistent/issues/646
        fkPragma
          | _fkEnabled connInfo = ("PRAGMA foreign_keys = on;":)
          | otherwise = id

        -- Allow arbitrary additional pragmas to be set
        -- https://github.com/commercialhaskell/stack/issues/4247
        pragmas = walPragma $ fkPragma $ _extraPragmas connInfo

    forM_ pragmas $ \pragma -> do
        stmt <- Sqlite.prepare conn pragma
        _ <- Sqlite.stepConn conn stmt
        Sqlite.reset conn stmt
        Sqlite.finalize stmt

    smap <- newIORef $ Map.empty
    return . mkPersistBackend $ SqlBackend
        { connPrepare = prepare' conn
        , connStmtMap = smap
        , connInsertSql = insertSql'
        , connUpsertSql = Nothing
        , connPutManySql = Just putManySql
        , connInsertManySql = Nothing
        , connClose = Sqlite.close conn
        , connMigrateSql = migrate'
        , connBegin = \f _ -> helper "BEGIN" f
        , connCommit = helper "COMMIT"
        , connRollback = ignoreExceptions . helper "ROLLBACK"
        , connEscapeName = escape
        , connNoLimit = "LIMIT -1"
        , connRDBMS = "sqlite"
        , connLimitOffset = decorateSQLWithLimitOffset "LIMIT -1"
        , connLogFunc = logFunc
        , connMaxParams = Just 999
        , connRepsertManySql = Just repsertManySql
        }
  where
    helper t getter = do
        stmt <- getter t
        _ <- stmtExecute stmt []
        stmtReset stmt
    ignoreExceptions = E.handle (\(_ :: E.SomeException) -> return ())

-- | A convenience helper which creates a new database connection and runs the
-- given block, handling @MonadResource@ and @MonadLogger@ requirements. Note
-- that all log messages are discarded.
--
-- @since 1.1.4
runSqlite :: (MonadUnliftIO m, IsSqlBackend backend)
          => Text -- ^ connection string
          -> ReaderT backend (NoLoggingT (ResourceT m)) a -- ^ database action
          -> m a
runSqlite connstr = runResourceT
                  . runNoLoggingT
                  . withSqliteConn connstr
                  . runSqlConn

-- | A convenience helper which creates a new database connection and runs the
-- given block, handling @MonadResource@ and @MonadLogger@ requirements. Note
-- that all log messages are discarded.
--
-- @since 2.6.2
runSqliteInfo :: (MonadUnliftIO m, IsSqlBackend backend)
              => SqliteConnectionInfo
              -> ReaderT backend (NoLoggingT (ResourceT m)) a -- ^ database action
              -> m a
runSqliteInfo conInfo = runResourceT
                      . runNoLoggingT
                      . withSqliteConnInfo conInfo
                      . runSqlConn

prepare' :: Sqlite.Connection -> Text -> IO Statement
prepare' conn sql = do
    stmt <- Sqlite.prepare conn sql
    return Statement
        { stmtFinalize = Sqlite.finalize stmt
        , stmtReset = Sqlite.reset conn stmt
        , stmtExecute = execute' conn stmt
        , stmtQuery = withStmt' conn stmt
        }

insertSql' :: EntityDef -> [PersistValue] -> InsertSqlResult
insertSql' ent vals =
  case entityPrimary ent of
    Just _ ->
      ISRManyKeys sql vals
        where sql = T.concat
                [ "INSERT INTO "
                , escape $ entityDB ent
                , "("
                , T.intercalate "," $ map (escape . fieldDB) $ entityFields ent
                , ") VALUES("
                , T.intercalate "," (map (const "?") $ entityFields ent)
                , ")"
                ]
    Nothing ->
      ISRInsertGet ins sel
        where
          sel = T.concat
              [ "SELECT "
              , escape $ fieldDB (entityId ent)
              , " FROM "
              , escape $ entityDB ent
              , " WHERE _ROWID_=last_insert_rowid()"
              ]
          ins = T.concat
              [ "INSERT INTO "
              , escape $ entityDB ent
              , if null (entityFields ent)
                    then " VALUES(null)"
                    else T.concat
                      [ "("
                      , T.intercalate "," $ map (escape . fieldDB) $ entityFields ent
                      , ") VALUES("
                      , T.intercalate "," (map (const "?") $ entityFields ent)
                      , ")"
                      ]
              ]

execute' :: Sqlite.Connection -> Sqlite.Statement -> [PersistValue] -> IO Int64
execute' conn stmt vals = flip finally (liftIO $ Sqlite.reset conn stmt) $ do
    Sqlite.bind stmt vals
    _ <- Sqlite.stepConn conn stmt
    Sqlite.changes conn

withStmt'
          :: MonadIO m
          => Sqlite.Connection
          -> Sqlite.Statement
          -> [PersistValue]
          -> Acquire (ConduitM () [PersistValue] m ())
withStmt' conn stmt vals = do
    _ <- mkAcquire
        (Sqlite.bind stmt vals >> return stmt)
        (Sqlite.reset conn)
    return pull
  where
    pull = do
        x <- liftIO $ Sqlite.stepConn conn stmt
        case x of
            Sqlite.Done -> return ()
            Sqlite.Row -> do
                cols <- liftIO $ Sqlite.columns stmt
                yield cols
                pull

showSqlType :: SqlType -> Text
showSqlType SqlString = "VARCHAR"
showSqlType SqlInt32 = "INTEGER"
showSqlType SqlInt64 = "INTEGER"
showSqlType SqlReal = "REAL"
showSqlType (SqlNumeric precision scale) = T.concat [ "NUMERIC(", T.pack (show precision), ",", T.pack (show scale), ")" ]
showSqlType SqlDay = "DATE"
showSqlType SqlTime = "TIME"
showSqlType SqlDayTime = "TIMESTAMP"
showSqlType SqlBlob = "BLOB"
showSqlType SqlBool = "BOOLEAN"
showSqlType (SqlOther t) = t

migrate' :: [EntityDef]
         -> (Text -> IO Statement)
         -> EntityDef
         -> IO (Either [Text] [(Bool, Text)])
migrate' allDefs getter val = do
    let (cols, uniqs, _) = mkColumns allDefs val
    let newSql = mkCreateTable False def (filter (not . safeToRemove val . cName) cols, uniqs)
    stmt <- getter "SELECT sql FROM sqlite_master WHERE type='table' AND name=?"
    oldSql' <- with (stmtQuery stmt [PersistText $ unDBName table])
      (\src -> runConduit $ src .| go)
    case oldSql' of
        Nothing -> return $ Right [(False, newSql)]
        Just oldSql -> do
            if oldSql == newSql
                then return $ Right []
                else do
                    sql <- getCopyTable allDefs getter val
                    return $ Right sql
  where
    def = val
    table = entityDB def
    go = do
        x <- CL.head
        case x of
            Nothing -> return Nothing
            Just [PersistText y] -> return $ Just y
            Just y -> error $ "Unexpected result from sqlite_master: " ++ show y

-- | Mock a migration even when the database is not present.
-- This function performs the same functionality of 'printMigration'
-- with the difference that an actual database isn't needed for it.
mockMigration :: Migration -> IO ()
mockMigration mig = do
  smap <- newIORef $ Map.empty
  let sqlbackend = SqlBackend
                   { connPrepare = \_ -> do
                                     return Statement
                                                { stmtFinalize = return ()
                                                , stmtReset = return ()
                                                , stmtExecute = undefined
                                                , stmtQuery = \_ -> return $ return ()
                                                }
                   , connStmtMap = smap
                   , connInsertSql = insertSql'
                   , connInsertManySql = Nothing
                   , connClose = undefined
                   , connMigrateSql = migrate'
                   , connBegin = \f _ -> helper "BEGIN" f
                   , connCommit = helper "COMMIT"
                   , connRollback = ignoreExceptions . helper "ROLLBACK"
                   , connEscapeName = escape
                   , connNoLimit = "LIMIT -1"
                   , connRDBMS = "sqlite"
                   , connLimitOffset = decorateSQLWithLimitOffset "LIMIT -1"
                   , connLogFunc = undefined
                   , connUpsertSql = undefined
                   , connPutManySql = undefined
                   , connMaxParams = Just 999
                   , connRepsertManySql = Nothing
                   }
      result = runReaderT . runWriterT . runWriterT $ mig
  resp <- result sqlbackend
  mapM_ TIO.putStrLn $ map snd $ snd resp
    where
      helper t getter = do
                      stmt <- getter t
                      _ <- stmtExecute stmt []
                      stmtReset stmt
      ignoreExceptions = E.handle (\(_ :: E.SomeException) -> return ())

-- | Check if a column name is listed as the "safe to remove" in the entity
-- list.
safeToRemove :: EntityDef -> DBName -> Bool
safeToRemove def (DBName colName)
    = any (elem "SafeToRemove" . fieldAttrs)
    $ filter ((== DBName colName) . fieldDB)
    $ entityFields def

getCopyTable :: [EntityDef]
             -> (Text -> IO Statement)
             -> EntityDef
             -> IO [(Bool, Text)]
getCopyTable allDefs getter def = do
    stmt <- getter $ T.concat [ "PRAGMA table_info(", escape table, ")" ]
    oldCols' <- with (stmtQuery stmt []) (\src -> runConduit $ src .| getCols)
    let oldCols = map DBName $ filter (/= "id") oldCols' -- need to update for table id attribute ?
    let newCols = filter (not . safeToRemove def) $ map cName cols
    let common = filter (`elem` oldCols) newCols
    let id_ = fieldDB (entityId def)
    return [ (False, tmpSql)
           , (False, copyToTemp $ id_ : common)
           , (common /= filter (not . safeToRemove def) oldCols, dropOld)
           , (False, newSql)
           , (False, copyToFinal $ id_ : newCols)
           , (False, dropTmp)
           ]
  where
    getCols = do
        x <- CL.head
        case x of
            Nothing -> return []
            Just (_:PersistText name:_) -> do
                names <- getCols
                return $ name : names
            Just y -> error $ "Invalid result from PRAGMA table_info: " ++ show y
    table = entityDB def
    tableTmp = DBName $ unDBName table <> "_backup"
    (cols, uniqs, _) = mkColumns allDefs def
    cols' = filter (not . safeToRemove def . cName) cols
    newSql = mkCreateTable False def (cols', uniqs)
    tmpSql = mkCreateTable True def { entityDB = tableTmp } (cols', uniqs)
    dropTmp = "DROP TABLE " <> escape tableTmp
    dropOld = "DROP TABLE " <> escape table
    copyToTemp common = T.concat
        [ "INSERT INTO "
        , escape tableTmp
        , "("
        , T.intercalate "," $ map escape common
        , ") SELECT "
        , T.intercalate "," $ map escape common
        , " FROM "
        , escape table
        ]
    copyToFinal newCols = T.concat
        [ "INSERT INTO "
        , escape table
        , " SELECT "
        , T.intercalate "," $ map escape newCols
        , " FROM "
        , escape tableTmp
        ]

mkCreateTable :: Bool -> EntityDef -> ([Column], [UniqueDef]) -> Text
mkCreateTable isTemp entity (cols, uniqs) =
  case entityPrimary entity of
    Just pdef ->
       T.concat
        [ "CREATE"
        , if isTemp then " TEMP" else ""
        , " TABLE "
        , escape $ entityDB entity
        , "("
        , T.drop 1 $ T.concat $ map (sqlColumn isTemp) cols
        , ", PRIMARY KEY "
        , "("
        , T.intercalate "," $ map (escape . fieldDB) $ compositeFields pdef
        , ")"
        , ")"
        ]
    Nothing -> T.concat
        [ "CREATE"
        , if isTemp then " TEMP" else ""
        , " TABLE "
        , escape $ entityDB entity
        , "("
        , escape $ fieldDB (entityId entity)
        , " "
        , showSqlType $ fieldSqlType $ entityId entity
        ," PRIMARY KEY"
        , mayDefault $ defaultAttribute $ fieldAttrs $ entityId entity
        , T.concat $ map (sqlColumn isTemp) cols
        , T.concat $ map sqlUnique uniqs
        , ")"
        ]

mayDefault :: Maybe Text -> Text
mayDefault def = case def of
    Nothing -> ""
    Just d -> " DEFAULT " <> d

sqlColumn :: Bool -> Column -> Text
sqlColumn noRef (Column name isNull typ def _cn _maxLen ref) = T.concat
    [ ","
    , escape name
    , " "
    , showSqlType typ
    , if isNull then " NULL" else " NOT NULL"
    , mayDefault def
    , case ref of
        Nothing -> ""
        Just (table, _) -> if noRef then "" else " REFERENCES " <> escape table
    ]

sqlUnique :: UniqueDef -> Text
sqlUnique (UniqueDef _ cname cols _) = T.concat
    [ ",CONSTRAINT "
    , escape cname
    , " UNIQUE ("
    , T.intercalate "," $ map (escape . snd) cols
    , ")"
    ]

escape :: DBName -> Text
escape (DBName s) =
    T.concat [q, T.concatMap go s, q]
  where
    q = T.singleton '"'
    go '"' = "\"\""
    go c = T.singleton c

putManySql :: EntityDef -> Int -> Text
putManySql ent n = putManySql' conflictColumns fields ent n
  where
    fields = entityFields ent
    conflictColumns = concatMap (map (escape . snd) . uniqueFields) (entityUniques ent)

repsertManySql :: EntityDef -> Int -> Text
repsertManySql ent n = putManySql' conflictColumns fields ent n
  where
    fields = keyAndEntityFields ent
    conflictColumns = escape . fieldDB <$> entityKeyFields ent

putManySql' :: [Text] -> [FieldDef] -> EntityDef -> Int -> Text
putManySql' conflictColumns fields ent n = q
  where
    fieldDbToText = escape . fieldDB
    mkAssignment f = T.concat [f, "=EXCLUDED.", f]

    table = escape . entityDB $ ent
    columns = Util.commaSeparated $ map fieldDbToText fields
    placeholders = map (const "?") fields
    updates = map (mkAssignment . fieldDbToText) fields

    q = T.concat
        [ "INSERT INTO "
        , table
        , Util.parenWrapped columns
        , " VALUES "
        , Util.commaSeparated . replicate n
            . Util.parenWrapped . Util.commaSeparated $ placeholders
        , " ON CONFLICT "
        , Util.parenWrapped . Util.commaSeparated $ conflictColumns
        , " DO UPDATE SET "
        , Util.commaSeparated updates
        ]

-- | Information required to setup a connection pool.
data SqliteConf = SqliteConf
    { sqlDatabase :: Text
    , sqlPoolSize :: Int
    }
    | SqliteConfInfo
    { sqlConnInfo :: SqliteConnectionInfo
    , sqlPoolSize :: Int
    } deriving Show

instance FromJSON SqliteConf where
    parseJSON v = modifyFailure ("Persistent: error loading Sqlite conf: " ++) $ flip (withObject "SqliteConf") v parser where
        parser o = if HashMap.member "database" o
                      then SqliteConf
                            A.<$> o .: "database"
                            A.<*> o .: "poolsize"
                      else SqliteConfInfo
                            A.<$> o .: "connInfo"
                            A.<*> o .: "poolsize"

instance PersistConfig SqliteConf where
    type PersistConfigBackend SqliteConf = SqlPersistT
    type PersistConfigPool SqliteConf = ConnectionPool
    createPoolConfig (SqliteConf cs size) = runNoLoggingT $ createSqlitePoolFromInfo (conStringToInfo cs) size -- FIXME
    createPoolConfig (SqliteConfInfo info size) = runNoLoggingT $ createSqlitePoolFromInfo info size -- FIXME
    runPool _ = runSqlPool
    loadConfig = parseJSON

finally :: MonadUnliftIO m
        => m a -- ^ computation to run first
        -> m b -- ^ computation to run afterward (even if an exception was raised)
        -> m a
finally a sequel = withUnliftIO $ \u ->
                     E.finally (unliftIO u a)
                               (unliftIO u sequel)
{-# INLINABLE finally #-}
-- | Creates a SqliteConnectionInfo from a connection string, with the
-- default settings.
--
-- @since 2.6.2
mkSqliteConnectionInfo :: Text -> SqliteConnectionInfo
mkSqliteConnectionInfo fp = SqliteConnectionInfo fp True True []

-- | Parses connection options from a connection string. Used only to provide deprecated API.
conStringToInfo :: Text -> SqliteConnectionInfo
conStringToInfo connStr = SqliteConnectionInfo connStr' enableWal True [] where
    (connStr', enableWal) = case () of
        ()
            | Just cs <- T.stripPrefix "WAL=on "  connStr -> (cs, True)
            | Just cs <- T.stripPrefix "WAL=off " connStr -> (cs, False)
            | otherwise                                   -> (connStr, True)

-- | Information required to connect to a sqlite database. We export
-- lenses instead of fields to avoid being limited to the current
-- implementation.
--
-- @since 2.6.2
data SqliteConnectionInfo = SqliteConnectionInfo
    { _sqlConnectionStr :: Text -- ^ connection string for the database. Use @:memory:@ for an in-memory database.
    , _walEnabled :: Bool -- ^ if the write-ahead log is enabled - see https://github.com/yesodweb/persistent/issues/363.
    , _fkEnabled :: Bool -- ^ if foreign-key constraints are enabled.
    , _extraPragmas :: [Text] -- ^ additional pragmas to be set on initialization
    } deriving Show
makeLenses ''SqliteConnectionInfo

instance FromJSON SqliteConnectionInfo where
    parseJSON v = modifyFailure ("Persistent: error loading SqliteConnectionInfo: " ++) $
      flip (withObject "SqliteConnectionInfo") v $ \o -> SqliteConnectionInfo
        <$> o .: "connectionString"
        <*> o .: "walEnabled"
        <*> o .: "fkEnabled"
        <*> o .:? "extraPragmas" .!= []
