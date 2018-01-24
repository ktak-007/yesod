{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances #-}
module Yesod.Core.Types where

import qualified Data.ByteString.Builder            as BB
#if __GLASGOW_HASKELL__ < 710
import           Control.Applicative                (Applicative (..))
import           Control.Applicative                ((<$>))
import           Data.Monoid                        (Monoid (..))
#endif
import           Control.Arrow                      (first)
import           Control.Exception                  (Exception)
import           Control.Monad                      (ap)
import           Control.Monad.IO.Class             (MonadIO (liftIO))
import           Control.Monad.Logger               (LogLevel, LogSource,
                                                     MonadLogger (..))
import           Control.Monad.Trans.Resource       (MonadResource (..), InternalState, runInternalState, MonadThrow (..), ResourceT)
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString.Lazy               as L
import           Data.CaseInsensitive               (CI)
import           Data.Conduit                       (Flush, ConduitT)
import           Data.IORef                         (IORef, modifyIORef')
import           Data.Map                           (Map, unionWith)
import qualified Data.Map                           as Map
import           Data.Monoid                        (Endo (..), Last (..))
import           Data.Serialize                     (Serialize (..),
                                                     putByteString)
import           Data.String                        (IsString (fromString))
import           Data.Text                          (Text)
import qualified Data.Text                          as T
import qualified Data.Text.Lazy.Builder             as TBuilder
import           Data.Time                          (UTCTime)
import           Data.Typeable                      (Typeable)
import           GHC.Generics                       (Generic)
import           Language.Haskell.TH.Syntax         (Loc)
import qualified Network.HTTP.Types                 as H
import           Network.Wai                        (FilePart,
                                                     RequestBodyLength)
import qualified Network.Wai                        as W
import qualified Network.Wai.Parse                  as NWP
import           System.Log.FastLogger              (LogStr, LoggerSet, toLogStr, pushLogStr)
import           Network.Wai.Logger                 (DateCacheGetter)
import           Text.Blaze.Html                    (Html, toHtml)
import           Text.Hamlet                        (HtmlUrl)
import           Text.Julius                        (JavascriptUrl)
import           Web.Cookie                         (SetCookie)
import           Yesod.Core.Internal.Util           (getTime, putTime)
import           Yesod.Routes.Class                 (RenderRoute (..), ParseRoute (..))
import           Control.Monad.Reader               (MonadReader (..))
import           Data.Monoid                        ((<>))
import Control.DeepSeq (NFData (rnf))
import Control.DeepSeq.Generics (genericRnf)
import Yesod.Core.TypeCache (TypeMap, KeyedTypeMap)
import Control.Monad.Logger (MonadLoggerIO (..))
import Data.Semigroup (Semigroup)
import UnliftIO (MonadUnliftIO (..), UnliftIO (..))

-- Sessions
type SessionMap = Map Text ByteString

type SaveSession = SessionMap -- ^ The session contents after running the handler
                -> IO [Header]

newtype SessionBackend = SessionBackend
    { sbLoadSession :: W.Request
                    -> IO (SessionMap, SaveSession) -- ^ Return the session data and a function to save the session
    }

data SessionCookie = SessionCookie !(Either UTCTime ByteString) !ByteString !SessionMap
    deriving (Show, Read)
instance Serialize SessionCookie where
    put (SessionCookie a b c) = do
        either putTime putByteString a
        put b
        put (map (first T.unpack) $ Map.toList c)

    get = do
        a <- getTime
        b <- get
        c <- map (first T.pack) <$> get
        return $ SessionCookie (Left a) b (Map.fromList c)

data ClientSessionDateCache =
  ClientSessionDateCache {
    csdcNow               :: !UTCTime
  , csdcExpires           :: !UTCTime
  , csdcExpiresSerialized :: !ByteString
  } deriving (Eq, Show)

-- | The parsed request information. This type augments the standard WAI
-- 'W.Request' with additional information.
data YesodRequest = YesodRequest
    { reqGetParams  :: ![(Text, Text)]
      -- ^ Same as 'W.queryString', but decoded to @Text@.
    , reqCookies    :: ![(Text, Text)]
    , reqWaiRequest :: !W.Request
    , reqLangs      :: ![Text]
      -- ^ Languages which the client supports. This is an ordered list by preference.
    , reqToken      :: !(Maybe Text)
      -- ^ A random, session-specific token used to prevent CSRF attacks.
    , reqSession    :: !SessionMap
      -- ^ Initial session sent from the client.
      --
      -- Since 1.2.0
    , reqAccept     :: ![ContentType]
      -- ^ An ordered list of the accepted content types.
      --
      -- Since 1.2.0
    }

-- | An augmented WAI 'W.Response'. This can either be a standard @Response@,
-- or a higher-level data structure which Yesod will turn into a @Response@.
data YesodResponse
    = YRWai !W.Response
    | YRWaiApp !W.Application
    | YRPlain !H.Status ![Header] !ContentType !Content !SessionMap

-- | A tuple containing both the POST parameters and submitted files.
type RequestBodyContents =
    ( [(Text, Text)]
    , [(Text, FileInfo)]
    )

data FileInfo = FileInfo
    { fileName        :: !Text
    , fileContentType :: !Text
    , fileSourceRaw   :: !(ConduitT () ByteString (ResourceT IO) ())
    , fileMove        :: !(FilePath -> IO ())
    }

data FileUpload = FileUploadMemory !(NWP.BackEnd L.ByteString)
                | FileUploadDisk !(InternalState -> NWP.BackEnd FilePath)
                | FileUploadSource !(NWP.BackEnd (ConduitT () ByteString (ResourceT IO) ()))

-- | How to determine the root of the application for constructing URLs.
--
-- Note that future versions of Yesod may add new constructors without bumping
-- the major version number. As a result, you should /not/ pattern match on
-- @Approot@ values.
data Approot master = ApprootRelative -- ^ No application root.
                    | ApprootStatic !Text
                    | ApprootMaster !(master -> Text)
                    | ApprootRequest !(master -> W.Request -> Text)

type ResolvedApproot = Text

data AuthResult = Authorized | AuthenticationRequired | Unauthorized !Text
    deriving (Eq, Show, Read)

data ScriptLoadPosition master
    = BottomOfBody
    | BottomOfHeadBlocking
    | BottomOfHeadAsync !(BottomOfHeadAsync master)

type BottomOfHeadAsync master
       = [Text] -- ^ urls to load asynchronously
      -> Maybe (HtmlUrl (Route master)) -- ^ widget of js to run on async completion
      -> HtmlUrl (Route master) -- ^ widget to insert at the bottom of <head>

type Texts = [Text]

-- | Wrap up a normal WAI application as a Yesod subsite. Ignore parent site's middleware and isAuthorized.
newtype WaiSubsite = WaiSubsite { runWaiSubsite :: W.Application }

-- | Like 'WaiSubsite', but applies parent site's middleware and isAuthorized.
--
-- @since 1.4.34
newtype WaiSubsiteWithAuth = WaiSubsiteWithAuth { runWaiSubsiteWithAuth :: W.Application }

data RunHandlerEnv child site = RunHandlerEnv
    { rheRender   :: !(Route site -> [(Text, Text)] -> Text)
    , rheRoute    :: !(Maybe (Route child))
    , rheRouteToMaster :: !(Route child -> Route site)
    , rheSite     :: !site
    , rheChild    :: !child
    , rheUpload   :: !(RequestBodyLength -> FileUpload)
    , rheLog      :: !(Loc -> LogSource -> LogLevel -> LogStr -> IO ())
    , rheOnError  :: !(ErrorResponse -> YesodApp)
      -- ^ How to respond when an error is thrown internally.
      --
      -- Since 1.2.0
    , rheMaxExpires :: !Text
    }

data HandlerData child site = HandlerData
    { handlerRequest  :: !YesodRequest
    , handlerEnv      :: !(RunHandlerEnv child site)
    , handlerState    :: !(IORef GHState)
    , handlerResource :: !InternalState
    }

data YesodRunnerEnv site = YesodRunnerEnv
    { yreLogger         :: !Logger
    , yreSite           :: !site
    , yreSessionBackend :: !(Maybe SessionBackend)
    , yreGen            :: !(IO Int)
    -- ^ Generate a random number
    , yreGetMaxExpires  :: !(IO Text)
    }

data YesodSubRunnerEnv sub parent = YesodSubRunnerEnv
    { ysreParentRunner  :: !(ParentRunner parent)
    , ysreGetSub        :: !(parent -> sub)
    , ysreToParentRoute :: !(Route sub -> Route parent)
    , ysreParentEnv     :: !(YesodRunnerEnv parent) -- FIXME maybe get rid of this and remove YesodRunnerEnv in ParentRunner?
    }

type ParentRunner parent
    = HandlerFor parent TypedContent
   -> YesodRunnerEnv parent
   -> Maybe (Route parent)
   -> W.Application

-- | A generic handler monad, which can have a different subsite and master
-- site. We define a newtype for better error message.
newtype HandlerFor site a = HandlerFor
    { unHandlerFor :: HandlerData site site -> IO a
    }
    deriving Functor

data GHState = GHState
    { ghsSession :: !SessionMap
    , ghsRBC     :: !(Maybe RequestBodyContents)
    , ghsIdent   :: !Int
    , ghsCache   :: !TypeMap
    , ghsCacheBy :: !KeyedTypeMap
    , ghsHeaders :: !(Endo [Header])
    }

-- | An extension of the basic WAI 'W.Application' datatype to provide extra
-- features needed by Yesod. Users should never need to use this directly, as
-- the 'HandlerT' monad and template haskell code should hide it away.
type YesodApp = YesodRequest -> ResourceT IO YesodResponse

-- | A generic widget, allowing specification of both the subsite and master
-- site datatypes. While this is simply a @WriterT@, we define a newtype for
-- better error messages.
newtype WidgetFor site a = WidgetFor
    { unWidgetFor :: WidgetData site -> IO a
    }
    deriving Functor

data WidgetData site = WidgetData
  { wdRef :: {-# UNPACK #-} !(IORef (GWData (Route site)))
  , wdHandler :: {-# UNPACK #-} !(HandlerData site site)
  }

instance a ~ () => Monoid (WidgetFor site a) where
    mempty = return ()
    mappend x y = x >> y
instance a ~ () => Semigroup (WidgetFor site a)

-- | A 'String' can be trivially promoted to a widget.
--
-- For example, in a yesod-scaffold site you could use:
--
-- @getHomeR = do defaultLayout "Widget text"@
instance a ~ () => IsString (WidgetFor site a) where
    fromString = toWidget . toHtml . T.pack
      where toWidget x = tellWidget mempty { gwdBody = Body (const x) }

tellWidget :: GWData (Route site) -> WidgetFor site ()
tellWidget d = WidgetFor $ \wd -> modifyIORef' (wdRef wd) (<> d)

type RY master = Route master -> [(Text, Text)] -> Text

-- | Newtype wrapper allowing injection of arbitrary content into CSS.
--
-- Usage:
--
-- > toWidget $ CssBuilder "p { color: red }"
--
-- Since: 1.1.3
newtype CssBuilder = CssBuilder { unCssBuilder :: TBuilder.Builder }

-- | Content for a web page. By providing this datatype, we can easily create
-- generic site templates, which would have the type signature:
--
-- > PageContent url -> HtmlUrl url
data PageContent url = PageContent
    { pageTitle :: !Html
    , pageHead  :: !(HtmlUrl url)
    , pageBody  :: !(HtmlUrl url)
    }

data Content = ContentBuilder !BB.Builder !(Maybe Int) -- ^ The content and optional content length.
             | ContentSource !(ConduitT () (Flush BB.Builder) (ResourceT IO) ())
             | ContentFile !FilePath !(Maybe FilePart)
             | ContentDontEvaluate !Content

data TypedContent = TypedContent !ContentType !Content

type RepHtml = Html
{-# DEPRECATED RepHtml "Please use Html instead" #-}
newtype RepJson = RepJson Content
newtype RepPlain = RepPlain Content
newtype RepXml = RepXml Content

type ContentType = ByteString -- FIXME Text?

-- | Prevents a response body from being fully evaluated before sending the
-- request.
--
-- Since 1.1.0
newtype DontFullyEvaluate a = DontFullyEvaluate { unDontFullyEvaluate :: a }

-- | Responses to indicate some form of an error occurred.
data ErrorResponse =
      NotFound
    | InternalError !Text
    | InvalidArgs ![Text]
    | NotAuthenticated
    | PermissionDenied !Text
    | BadMethod !H.Method
    deriving (Show, Eq, Typeable, Generic)
instance NFData ErrorResponse where
    rnf = genericRnf

----- header stuff
-- | Headers to be added to a 'Result'.
data Header =
      AddCookie !SetCookie
    | DeleteCookie !ByteString !ByteString
    -- ^ name and path
    | Header !(CI ByteString) !ByteString
    -- ^ key and value
    deriving (Eq, Show)

-- FIXME In the next major version bump, let's just add strictness annotations
-- to Header (and probably everywhere else). We can also add strictness
-- annotations to SetCookie in the cookie package.
instance NFData Header where
    rnf (AddCookie x) = rnf x
    rnf (DeleteCookie x y) = x `seq` y `seq` ()
    rnf (Header x y) = x `seq` y `seq` ()

data Location url = Local !url | Remote !Text
    deriving (Show, Eq)

-- | A diff list that does not directly enforce uniqueness.
-- When creating a widget Yesod will use nub to make it unique.
newtype UniqueList x = UniqueList ([x] -> [x])

data Script url = Script { scriptLocation :: !(Location url), scriptAttributes :: ![(Text, Text)] }
    deriving (Show, Eq)
data Stylesheet url = Stylesheet { styleLocation :: !(Location url), styleAttributes :: ![(Text, Text)] }
    deriving (Show, Eq)
newtype Title = Title { unTitle :: Html }

newtype Head url = Head (HtmlUrl url)
    deriving Monoid
instance Semigroup (Head a)
newtype Body url = Body (HtmlUrl url)
    deriving Monoid
instance Semigroup (Body a)

type CssBuilderUrl a = (a -> [(Text, Text)] -> Text) -> TBuilder.Builder

data GWData a = GWData
    { gwdBody        :: !(Body a)
    , gwdTitle       :: !(Last Title)
    , gwdScripts     :: !(UniqueList (Script a))
    , gwdStylesheets :: !(UniqueList (Stylesheet a))
    , gwdCss         :: !(Map (Maybe Text) (CssBuilderUrl a)) -- media type
    , gwdJavascript  :: !(Maybe (JavascriptUrl a))
    , gwdHead        :: !(Head a)
    }
instance Monoid (GWData a) where
    mempty = GWData mempty mempty mempty mempty mempty mempty mempty
    mappend (GWData a1 a2 a3 a4 a5 a6 a7)
            (GWData b1 b2 b3 b4 b5 b6 b7) = GWData
        (a1 `mappend` b1)
        (a2 `mappend` b2)
        (a3 `mappend` b3)
        (a4 `mappend` b4)
        (unionWith mappend a5 b5)
        (a6 `mappend` b6)
        (a7 `mappend` b7)
instance Semigroup (GWData a)

data HandlerContents =
      HCContent !H.Status !TypedContent
    | HCError !ErrorResponse
    | HCSendFile !ContentType !FilePath !(Maybe FilePart)
    | HCRedirect !H.Status !Text
    | HCCreated !Text
    | HCWai !W.Response
    | HCWaiApp !W.Application
    deriving Typeable

instance Show HandlerContents where
    show (HCContent status (TypedContent t _)) = "HCContent " ++ show (status, t)
    show (HCError e) = "HCError " ++ show e
    show (HCSendFile ct fp mfp) = "HCSendFile " ++ show (ct, fp, mfp)
    show (HCRedirect s t) = "HCRedirect " ++ show (s, t)
    show (HCCreated t) = "HCCreated " ++ show t
    show (HCWai _) = "HCWai"
    show (HCWaiApp _) = "HCWaiApp"
instance Exception HandlerContents

-- Instances for WidgetFor
instance Applicative (WidgetFor site) where
    pure = WidgetFor . const . pure
    (<*>) = ap
instance Monad (WidgetFor site) where
    return = pure
    WidgetFor x >>= f = WidgetFor $ \wd -> do
        a <- x wd
        unWidgetFor (f a) wd
instance MonadIO (WidgetFor site) where
    liftIO = WidgetFor . const
-- | @since 1.4.38
instance MonadUnliftIO (WidgetFor site) where
  {-# INLINE askUnliftIO #-}
  askUnliftIO = WidgetFor $ \wd ->
                return (UnliftIO (flip unWidgetFor wd))
instance MonadReader (WidgetData site) (WidgetFor site) where
    ask = WidgetFor return
    local f (WidgetFor g) = WidgetFor $ g . f

instance MonadThrow (WidgetFor site) where
    throwM = liftIO . throwM

instance MonadResource (WidgetFor site) where
    liftResourceT f = WidgetFor $ runInternalState f . handlerResource . wdHandler

instance MonadLogger (WidgetFor site) where
    monadLoggerLog a b c d = WidgetFor $ \wd ->
        rheLog (handlerEnv $ wdHandler wd) a b c (toLogStr d)

instance MonadLoggerIO (WidgetFor site) where
    askLoggerIO = WidgetFor $ return . rheLog . handlerEnv . wdHandler

-- Instances for HandlerT
instance Applicative (HandlerFor site) where
    pure = HandlerFor . const . return
    (<*>) = ap
instance Monad (HandlerFor site) where
    return = pure
    HandlerFor x >>= f = HandlerFor $ \r -> x r >>= \x' -> unHandlerFor (f x') r
instance MonadIO (HandlerFor site) where
    liftIO = HandlerFor . const
instance MonadReader (HandlerData site site) (HandlerFor site) where
    ask = HandlerFor return
    local f (HandlerFor g) = HandlerFor $ g . f

-- | @since 1.4.38
instance MonadUnliftIO (HandlerFor site) where
  {-# INLINE askUnliftIO #-}
  askUnliftIO = HandlerFor $ \r ->
                return (UnliftIO (flip unHandlerFor r))

instance MonadThrow (HandlerFor site) where
    throwM = liftIO . throwM

instance MonadResource (HandlerFor site) where
    liftResourceT f = HandlerFor $ runInternalState f . handlerResource

instance MonadLogger (HandlerFor site) where
    monadLoggerLog a b c d = HandlerFor $ \hd ->
        rheLog (handlerEnv hd) a b c (toLogStr d)

instance MonadLoggerIO (HandlerFor site) where
    askLoggerIO = HandlerFor $ \hd -> return (rheLog (handlerEnv hd))

instance Monoid (UniqueList x) where
    mempty = UniqueList id
    UniqueList x `mappend` UniqueList y = UniqueList $ x . y
instance Semigroup (UniqueList x)

instance IsString Content where
    fromString = flip ContentBuilder Nothing . BB.stringUtf8

instance RenderRoute WaiSubsite where
    data Route WaiSubsite = WaiSubsiteRoute [Text] [(Text, Text)]
        deriving (Show, Eq, Read, Ord)
    renderRoute (WaiSubsiteRoute ps qs) = (ps, qs)
instance ParseRoute WaiSubsite where
    parseRoute (x, y) = Just $ WaiSubsiteRoute x y

instance RenderRoute WaiSubsiteWithAuth where
  data Route WaiSubsiteWithAuth = WaiSubsiteWithAuthRoute [Text] [(Text,Text)]
       deriving (Show, Eq, Read, Ord)
  renderRoute (WaiSubsiteWithAuthRoute ps qs) = (ps,qs)

instance ParseRoute WaiSubsiteWithAuth where
  parseRoute (x, y) = Just $ WaiSubsiteWithAuthRoute x y

data Logger = Logger
    { loggerSet :: !LoggerSet
    , loggerDate :: !DateCacheGetter
    }

loggerPutStr :: Logger -> LogStr -> IO ()
loggerPutStr (Logger ls _) = pushLogStr ls

-- | A handler monad for subsite
--
-- @since 1.6.0
newtype SubHandlerFor sub master a = SubHandlerFor
    { unSubHandlerFor :: HandlerData sub master -> IO a
    }
    deriving Functor

instance Applicative (SubHandlerFor child master) where
    pure = SubHandlerFor . const . return
    (<*>) = ap
instance Monad (SubHandlerFor child master) where
    return = pure
    SubHandlerFor x >>= f = SubHandlerFor $ \r -> x r >>= \x' -> unSubHandlerFor (f x') r
instance MonadIO (SubHandlerFor child master) where
    liftIO = SubHandlerFor . const
instance MonadReader (HandlerData child master) (SubHandlerFor child master) where
    ask = SubHandlerFor return
    local f (SubHandlerFor g) = SubHandlerFor $ g . f

-- | @since 1.4.38
instance MonadUnliftIO (SubHandlerFor child master) where
  {-# INLINE askUnliftIO #-}
  askUnliftIO = SubHandlerFor $ \r ->
                return (UnliftIO (flip unSubHandlerFor r))

instance MonadThrow (SubHandlerFor child master) where
    throwM = liftIO . throwM

instance MonadResource (SubHandlerFor child master) where
    liftResourceT f = SubHandlerFor $ runInternalState f . handlerResource

instance MonadLogger (SubHandlerFor child master) where
    monadLoggerLog a b c d = SubHandlerFor $ \sd ->
        rheLog (handlerEnv sd) a b c (toLogStr d)

instance MonadLoggerIO (SubHandlerFor child master) where
    askLoggerIO = SubHandlerFor $ return . rheLog . handlerEnv
