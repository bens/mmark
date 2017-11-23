-- |
-- Module      :  Text.MMark.Parser
-- Copyright   :  © 2017 Mark Karpov
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov92@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- MMark parser.

{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE CPP                #-}
{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE MultiWayIf         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE TypeFamilies       #-}

module Text.MMark.Parser
  ( MMarkErr (..)
  , parse )
where

import Control.Applicative
import Control.DeepSeq
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Bifunctor (Bifunctor (..))
import Data.Data (Data)
import Data.Default.Class
import Data.List.NonEmpty (NonEmpty (..), (<|))
import Data.Maybe (isNothing, fromJust, fromMaybe)
import Data.Semigroup ((<>))
import Data.Text (Text)
import Data.Typeable (Typeable)
import Data.Void
import GHC.Generics
import Text.MMark.Internal
import Text.Megaparsec hiding (parse)
import Text.Megaparsec.Char hiding (eol)
import Text.URI (URI)
import qualified Control.Applicative.Combinators.NonEmpty as NE
import qualified Data.Char                  as Char
import qualified Data.List.NonEmpty         as NE
import qualified Data.Set                   as E
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import qualified Data.Yaml                  as Yaml
import qualified Text.Email.Validate        as Email
import qualified Text.Megaparsec.Char.Lexer as L
import qualified Text.URI                   as URI

----------------------------------------------------------------------------
-- Data types

-- | Block-level parser type. The 'Reader' monad inside allows to access
-- current reference level: 1 column for top-level of document, column where
-- content starts for block quotes and lists.

type BParser = ParsecT MMarkErr Text (Reader Pos)

-- | MMark custom parse errors.

data MMarkErr
  = YamlParseError String
    -- ^ YAML error that occurred during parsing of a YAML block
  | NonFlankingDelimiterRun (NonEmpty Char)
    -- ^ This delimiter run should be in left- or right- flanking position
  deriving (Eq, Ord, Show, Read, Generic, Typeable, Data)

instance ShowErrorComponent MMarkErr where
  showErrorComponent = \case
    YamlParseError str ->
      "YAML parse error: " ++ str
    NonFlankingDelimiterRun dels ->
      showTokens dels ++ " should be in left- or right- flanking position"

instance NFData MMarkErr

-- | Inline-level parser type. We store type of the last consumed character
-- in the state.

type IParser = StateT CharType (Parsec MMarkErr Text)

-- | 'Inline' source pending parsing.

data Isp = Isp SourcePos Text
  deriving (Eq, Ord, Show)

-- | Type of last seen character.

data CharType
  = SpaceChar          -- ^ White space or a transparent character
  | LeftFlankingDel    -- ^ Left flanking delimiter
  | RightFlankingDel   -- ^ Right flaking delimiter
  | OtherChar          -- ^ Other character
  deriving (Eq, Ord, Show)

-- | Frame that describes where we are in parsing inlines.

data InlineFrame
  = EmphasisFrame      -- ^ Emphasis with asterisk @*@
  | EmphasisFrame_     -- ^ Emphasis with underscore @_@
  | StrongFrame        -- ^ Strong emphasis with asterisk @**@
  | StrongFrame_       -- ^ Strong emphasis with underscore @__@
  | StrikeoutFrame     -- ^ Strikeout
  | SubscriptFrame     -- ^ Subscript
  | SuperscriptFrame   -- ^ Superscript
  deriving (Eq, Ord, Show)

-- | State of inline parsing that specifies whether we expect to close one
-- frame or there is a possibility to close one of two alternatives.

data InlineState
  = SingleFrame InlineFrame             -- ^ One frame to be closed
  | DoubleFrame InlineFrame InlineFrame -- ^ Two frames to be closed
  deriving (Eq, Ord, Show)

-- | Configuration of inline parser.

data InlineConfig = InlineConfig
  { iconfigAllowEmpty :: !Bool
    -- ^ Whether to accept empty inline blocks
  , iconfigAllowLinks :: !Bool
    -- ^ Whether to parse links
  , iconfigAllowImages :: !Bool
    -- ^ Whether to parse images
  }

instance Default InlineConfig where
  def = InlineConfig
    { iconfigAllowEmpty  = True
    , iconfigAllowLinks  = True
    , iconfigAllowImages = True
    }

-- | A shortcut type synonym for sub-parsers that may fail and we can
-- recover from the failure.

type E = Either (ParseError Char MMarkErr)

----------------------------------------------------------------------------
-- Block parser

-- | Parse a markdown document in the form of a strict 'Text' value and
-- either report parse errors or return a 'MMark' document. Note that the
-- parser has the ability to report multiple parse errors at once.

parse
  :: String
     -- ^ File name (only to be used in error messages), may be empty
  -> Text
     -- ^ Input to parse
  -> Either (NonEmpty (ParseError Char MMarkErr)) MMark
     -- ^ Parse errors or parsed document
parse file input =
  case runReader (runParserT p file input) pos1 of
    -- NOTE This parse error only happens when document structure on block
    -- level cannot be parsed even with recovery, which should not normally
    -- happen.
    Left err -> Left (nes err)
    Right (myaml, blocks) ->
      let parsed = doInline <$> blocks
          doInline = \case
            Left err -> Naked (Left err)
            Right x  -> first (replaceEof "end of inline block")
              . runIsp (pInlines def <* eof) <$> x
          getErrs (Left e) es = e : es
          getErrs _        es = es
          fromRight (Right x) = x
          fromRight _         =
            error "Text.MMark.Parser.parse: the impossible happened"
      in case NE.nonEmpty (foldMap (foldr getErrs []) parsed) of
           Nothing -> Right MMark
             { mmarkYaml      = myaml
             , mmarkBlocks    = fmap fromRight <$> parsed
             , mmarkExtension = mempty }
           Just es -> Left es
  where
    p = (,) <$> optional pYamlBlock
            <*> (setTabWidth (mkPos 4) *> many pBlock)

pYamlBlock :: BParser Yaml.Value
pYamlBlock = do
  dpos <- getPosition
  string "---" *> sc' *> eol
  let go = do
        l <- takeWhileP Nothing notNewline
        void (optional eol)
        e <- atEnd
        if e || T.stripEnd l == "---"
          then return []
          else (l :) <$> go
  ls <- go
  case (Yaml.decodeEither . TE.encodeUtf8 . T.intercalate "\n") ls of
    Left err' -> do
      let (apos, err) = splitYamlError (sourceName dpos) err'
      setPosition (fromMaybe dpos apos)
      (fancyFailure . E.singleton . ErrorCustom . YamlParseError) err
    Right v ->
      return v

pBlock :: BParser (E (Block Isp))
pBlock = do
  sc
  rlevel <- ask
  alevel <- L.indentLevel
  done   <- atEnd
  let b p = try (pure <$> p)
      l p =      pure <$> p
  if done || alevel < rlevel
    then empty
    else case compare alevel (ilevel rlevel) of
           LT -> choice
             [ b pThematicBreak
             ,   pAtxHeading
             , l pFencedCodeBlock
             , b pIndentedCodeBlock
             ,   pUnorderedList
             -- , l pOrderedList
             -- , l pBlockquote
             , l pParagraph ]
           _  ->
               b pIndentedCodeBlock

pThematicBreak :: BParser (Block Isp)
pThematicBreak = do
  void casualLevel
  l <- lookAhead nonEmptyLine
  if isThematicBreak l
    then ThematicBreak <$ nonEmptyLine <* sc
    else empty

pAtxHeading :: BParser (E (Block Isp))
pAtxHeading = do
  (void . lookAhead . try) start
  withRecovery recover $ do
    hlevel <- length <$> start
    sc1'
    ispPos <- getPosition
    r <- someTill (satisfy notNewline <?> "heading character") . try $
      optional (sc1' *> some (char '#') *> sc') *> (eof <|> eol)
    let toBlock = case hlevel of
          1 -> Heading1
          2 -> Heading2
          3 -> Heading3
          4 -> Heading4
          5 -> Heading5
          _ -> Heading6
    (Right . toBlock) (Isp ispPos (T.strip (T.pack r))) <$ sc
  where
    start = count' 1 6 (char '#')
    recover err =
      Left err <$ takeWhileP Nothing notNewline <* sc

pFencedCodeBlock :: BParser (Block Isp)
pFencedCodeBlock = do
  let p ch = try $ do
        void $ count 3 (char ch)
        n  <- (+ 3) . length <$> many (char ch)
        ml <- optional (T.strip <$> someEscapedWith notNewline <?> "info string")
        guard (maybe True (not . T.any (== '`')) ml)
        return
          (ch, n,
             case ml of
               Nothing -> Nothing
               Just l  ->
                 if T.null l
                   then Nothing
                   else Just l)
  (ch, n, infoString) <- (p '`' <|> p '~') <* eol
  let content = label "code block content" (option "" nonEmptyLine <* eol)
      closingFence = try . label "closing code fence" $ do
        void casualLevel'
        void $ count n (char ch)
        (void . many . char) ch
        sc'
        eof <|> eol
  ls <- manyTill content closingFence
  rlevel <- ask
  CodeBlock infoString (assembleCodeBlock rlevel ls) <$ sc

pIndentedCodeBlock :: BParser (Block Isp)
pIndentedCodeBlock = do
  initialIndent <- L.indentLevel
  let go ls = do
        immediate <- lookAhead (True <$ try codeBlockLevel' <|> pure False)
        eventual  <- lookAhead (True <$ try codeBlockLevel  <|> pure False)
        if not immediate && not eventual
          then return ls
          else do
            l        <- option "" nonEmptyLine
            continue <- eol'
            if continue
              then go (l:ls)
              else return (l:ls)
      -- NOTE This is a bit unfortunate, but it's difficult to guarantee
      -- that preceding space is not yet consumed when we get to
      -- interpreting input as an indented code block, so we need to restore
      -- the space this way.
      f x      = T.replicate (unPos initialIndent - 1) " " <> x
      g []     = []
      g (x:xs) = f x : xs
  ls <- g . reverse . dropWhile isBlank <$> go []
  rlevel <- ask
  CodeBlock Nothing (assembleCodeBlock (ilevel rlevel) ls) <$ sc

pUnorderedList :: BParser (E (Block Isp))
pUnorderedList = do
  let p :: BParser (E (Block Isp))
      p = do
        (void . try) (char '*' <* sc1')
        newRefLevel (sequence <$> many pBlock) -- FIXME

  -- TODO We either need a different way to collect parse errors on the
  -- block level, or we need to allow to return multiple parse erros in case
  -- of failure.

  -- TODO Before trying 'many pBlock' we need to try to parse a nacked
  -- paragraph. The parser for naked paragraph can be derived from existing
  -- pParagraph thing.

  xs <- NE.some p -- no idea how to re-arrange parse errors from p here

  return $ case r of
    Left err -> Left err
    Right xs -> Right (UnorderedList xs)

pOrderedList :: BParser (Block Isp)
pOrderedList = empty -- TODO

pBlockquote :: BParser (Block Isp)
pBlockquote = empty -- TODO

pParagraph :: BParser (Block Isp)
pParagraph = do
  void casualLevel
  startPos <- getPosition
  let go = do
        ml <- lookAhead (optional nonEmptyLine)
        case ml of
          Nothing -> return []
          Just l ->
            if isBlank l
              then return []
              else do
                void nonEmptyLine
                continue <- eol'
                (l :) <$> if continue then go else return []
  l        <- nonEmptyLine
  continue <- eol'
  ls       <- if continue then go else return []
  rlevel   <- ask
  Paragraph (Isp startPos (assembleParagraph rlevel (l:ls))) <$ sc

----------------------------------------------------------------------------
-- Inline parser

-- | Run a given parser on 'Isp'.

runIsp
  :: IParser a         -- ^ The parser to run
  -> Isp               -- ^ Input for the parser
  -> Either (ParseError Char MMarkErr) a -- ^ Result of parsing
runIsp p (Isp startPos input) =
  snd (runParser' (evalStateT p SpaceChar) pst)
  where
    pst = State
      { stateInput           = input
      , statePos             = nes startPos
      , stateTokensProcessed = 0
      , stateTabWidth        = mkPos 4 }

pInlines :: InlineConfig -> IParser (NonEmpty Inline)
pInlines InlineConfig {..} =
  if iconfigAllowEmpty
    then nes (Plain "") <$ eof <|> stuff
    else stuff
  where
    stuff = NE.some . label "inline content" . choice $
      [ pCodeSpan                                  ] <>
      [ pInlineLink           | iconfigAllowLinks  ] <>
      [ pImage                | iconfigAllowImages ] <>
      [ try (angel pAutolink) | iconfigAllowLinks  ] <>
      [ pEnclosedInline
      , try pHardLineBreak
      , pPlain ]
    angel = between (char '<') (char '>')

pCodeSpan :: IParser Inline
pCodeSpan = do
  n <- try (length <$> some (char '`'))
  let finalizer = try $ do
        void $ count n (char '`')
        notFollowedBy (char '`')
  r <- CodeSpan . collapseWhiteSpace . T.concat <$>
    manyTill (label "code span content" $
               takeWhile1P Nothing (== '`') <|>
               takeWhile1P Nothing (/= '`'))
      finalizer
  put OtherChar
  return r

pInlineLink :: IParser Inline
pInlineLink = do
  xs     <- between (char '[') (char ']') $
    pInlines def { iconfigAllowLinks = False }
  void (char '(') <* sc
  dest   <- pUri
  mtitle <- optional (sc1 *> pTitle)
  sc <* char ')'
  put OtherChar
  return (Link xs dest mtitle)

pImage :: IParser Inline
pImage = do
  let nonEmptyDesc = char '!' *> between (char '[') (char ']')
        (pInlines def { iconfigAllowImages = False })
  alt    <- nes (Plain "") <$ string "![]" <|> nonEmptyDesc
  void (char '(') <* sc
  src    <- pUri
  mtitle <- optional (sc1 *> pTitle)
  sc <* char ')'
  put OtherChar
  return (Image alt src mtitle)

pUri :: IParser URI
pUri = do
  uri <- between (char '<') (char '>') URI.parser <|> naked
  put OtherChar
  return uri
  where
    naked = do
      startPos <- getPosition
      input    <- takeWhileP Nothing $ \x ->
        not (isSpaceN x || x == ')')
      let pst = State
            { stateInput           = input
            , statePos             = nes startPos
            , stateTokensProcessed = 0
            , stateTabWidth        = mkPos 4 }
      case snd (runParser' (URI.parser <* eof) pst) of
        Left err' ->
          case replaceEof "end of URI literal" err' of
            TrivialError pos us es -> do
              setPosition (NE.head pos)
              failure us es
            FancyError pos xs -> do
              setPosition (NE.head pos)
              fancyFailure xs
        Right x -> return x

pTitle :: IParser Text
pTitle = choice
  [ p '\"' '\"'
  , p '\'' '\''
  , p '('  ')' ]
  where
    p start end = between (char start) (char end) $
      manyEscapedWith (/= end) "unescaped character"

pAutolink :: IParser Inline
pAutolink = do
  notFollowedBy (char '>') -- empty links don't make sense
  uri <- URI.parser
  put OtherChar
  return $ case isEmailUri uri of
    Nothing ->
      let txt = (nes . Plain . URI.render) uri
      in Link txt uri Nothing
    Just email ->
      let txt  = nes (Plain email)
          uri' = URI.makeAbsolute mailtoScheme uri
      in Link txt uri' Nothing

pEnclosedInline :: IParser Inline
pEnclosedInline = do
  let noEmpty = def { iconfigAllowEmpty = False }
  st <- choice
    [ pLfdr (DoubleFrame StrongFrame StrongFrame)
    , pLfdr (DoubleFrame StrongFrame EmphasisFrame)
    , pLfdr (SingleFrame StrongFrame)
    , pLfdr (SingleFrame EmphasisFrame)
    , pLfdr (DoubleFrame StrongFrame_ StrongFrame_)
    , pLfdr (DoubleFrame StrongFrame_ EmphasisFrame_)
    , pLfdr (SingleFrame StrongFrame_)
    , pLfdr (SingleFrame EmphasisFrame_)
    , pLfdr (DoubleFrame StrikeoutFrame StrikeoutFrame)
    , pLfdr (DoubleFrame StrikeoutFrame SubscriptFrame)
    , pLfdr (SingleFrame StrikeoutFrame)
    , pLfdr (SingleFrame SubscriptFrame)
    , pLfdr (SingleFrame SuperscriptFrame) ]
  case st of
    SingleFrame x ->
      liftFrame x <$> pInlines noEmpty <* pRfdr x
    DoubleFrame x y -> do
      inlines0  <- pInlines noEmpty
      thisFrame <- pRfdr x <|> pRfdr y
      let thatFrame = if x == thisFrame then y else x
      immediate <- True <$ pRfdr thatFrame <|> pure False
      if immediate
        then (return . liftFrame thatFrame . nes . liftFrame thisFrame) inlines0
        else do
          inlines1 <- pInlines noEmpty
          void (pRfdr thatFrame)
          return . liftFrame thatFrame $
            liftFrame thisFrame inlines0 <| inlines1

pLfdr :: InlineState -> IParser InlineState
pLfdr st = try $ do
  let dels = inlineStateDel st
  mpos <- getNextTokenPosition
  void (string dels)
  leftChar   <- get
  mrightChar <- lookAhead (optional anyChar)
  let failNow = do
        forM_ mpos setPosition
        (mmarkErr . NonFlankingDelimiterRun . toNesTokens) dels
  case (leftChar, isTransparent <$> mrightChar) of
    (_, Nothing)          -> failNow
    (_, Just True)        -> failNow
    (RightFlankingDel, _) -> failNow
    (OtherChar, _)        -> failNow
    (SpaceChar, _)        -> return ()
    (LeftFlankingDel, _)  -> return ()
  put LeftFlankingDel
  return st

pRfdr :: InlineFrame -> IParser InlineFrame
pRfdr frame = try $ do
  let dels = inlineFrameDel frame
  mpos <- getNextTokenPosition
  void (string dels)
  leftChar   <- get
  mrightChar <- lookAhead (optional anyChar)
  let failNow = do
        forM_ mpos setPosition
        (mmarkErr . NonFlankingDelimiterRun . toNesTokens) dels
  case (leftChar, mrightChar) of
    (SpaceChar, _) -> failNow
    (LeftFlankingDel, _) -> failNow
    (_, Nothing) -> return ()
    (_, Just rightChar) ->
      if | isTransparent rightChar -> return ()
         | isMarkupChar  rightChar -> return ()
         | otherwise               -> failNow
  put RightFlankingDel
  return frame

pHardLineBreak :: IParser Inline
pHardLineBreak = do
  void (char '\\')
  eol
  notFollowedBy eof
  sc'
  put SpaceChar
  return LineBreak

pPlain :: IParser Inline
pPlain = Plain . T.pack <$> some
  (pEscapedChar <|> pNewline <|> pNonEscapedChar)
  where
    pEscapedChar = escapedChar <* put OtherChar
    pNewline = hidden . try $
      '\n' <$ sc' <* eol <* sc' <* put SpaceChar
    pNonEscapedChar = label "unescaped non-markup character" . choice $
      [ try (char '\\' <* notFollowedBy eol)        <* put OtherChar
      , try (char '!'  <* notFollowedBy (char '[')) <* put SpaceChar
      , try (char '<'  <* notFollowedBy (pAutolink <* char '>')) <* put OtherChar
      , spaceChar                                   <* put SpaceChar
      , satisfy isTrans                             <* put SpaceChar
      , satisfy isOther                             <* put OtherChar ]
    isTrans x = isTransparentPunctuation x && x /= '!'
    isOther x = not (isMarkupChar x) && x /= '\\' && x /= '!' && x /= '<'

----------------------------------------------------------------------------
-- Block-level environment manipulations

casualLevel :: BParser Pos
casualLevel = do
  rlevel <- ask
  L.indentGuard sc LT (rlevel <> mkPos 4)

casualLevel' :: BParser Pos
casualLevel' = do
  rlevel <- ask
  L.indentGuard sc' LT (rlevel <> mkPos 4)

codeBlockLevel :: BParser Pos
codeBlockLevel = do
  rlevel <- ask
  L.indentGuard sc GT (rlevel <> mkPos 3)

codeBlockLevel' :: BParser Pos
codeBlockLevel' = do
  rlevel <- ask
  L.indentGuard sc' GT (rlevel <> mkPos 3)

newRefLevel :: BParser a -> BParser a
newRefLevel m = do
  c <- L.indentLevel
  local (const c) m

ilevel :: Pos -> Pos
ilevel = (<> mkPos 4)

----------------------------------------------------------------------------
-- Parsing helpers

nonEmptyLine :: BParser Text
nonEmptyLine = takeWhile1P Nothing notNewline

manyEscapedWith :: MonadParsec e Text m => (Char -> Bool) -> String -> m Text
manyEscapedWith f l = T.pack <$> many (escapedChar <|> (satisfy f <?> l))

someEscapedWith :: MonadParsec e Text m => (Char -> Bool) -> m Text
someEscapedWith f = T.pack <$> some (escapedChar <|> satisfy f)

escapedChar :: MonadParsec e Text m => m Char
escapedChar = try (char '\\' *> satisfy isAsciiPunctuation)
  <?> "escaped character"

sc :: MonadParsec e Text m => m ()
sc = void $ takeWhileP (Just "white space") isSpaceN

sc1 :: MonadParsec e Text m => m ()
sc1 = void $ takeWhile1P (Just "white space") isSpaceN

sc' :: MonadParsec e Text m => m ()
sc' = void $ takeWhileP (Just "white space") isSpace

sc1' :: MonadParsec e Text m => m ()
sc1' = void $ takeWhile1P (Just "white space") isSpace

eol :: MonadParsec e Text m => m ()
eol = void . label "newline" $ choice
  [ string "\n"
  , string "\r\n"
  , string "\r" ]

eol' :: MonadParsec e Text m => m Bool
eol' = option False (True <$ eol)

----------------------------------------------------------------------------
-- Block-level predicates

isThematicBreak :: Text -> Bool
isThematicBreak l' = T.length l >= 3 && indentLevel l' < 4 &&
  (T.all (== '*') l ||
   T.all (== '-') l ||
   T.all (== '_') l)
  where
    l = T.filter (not . isSpace) l'

----------------------------------------------------------------------------
-- Other helpers

isSpace :: Char -> Bool
isSpace x = x == ' ' || x == '\t'

isSpaceN :: Char -> Bool
isSpaceN x = isSpace x || x == '\n' || x == '\r'

notNewline :: Char -> Bool
notNewline x = x /= '\n' && x /= '\r'

isBlank :: Text -> Bool
isBlank = T.all isSpace

isMarkupChar :: Char -> Bool
isMarkupChar = \case
  '*' -> True
  '~' -> True
  '_' -> True
  '`' -> True
  '^' -> True
  '[' -> True
  ']' -> True
  _   -> False

isAsciiPunctuation :: Char -> Bool
isAsciiPunctuation x =
  (x >= '!' && x <= '/') ||
  (x >= ':' && x <= '@') ||
  (x >= '[' && x <= '`') ||
  (x >= '{' && x <= '~')

isTransparentPunctuation :: Char -> Bool
isTransparentPunctuation = \case
  '!' -> True
  '"' -> True
  '(' -> True
  ')' -> True
  ',' -> True
  '-' -> True
  '.' -> True
  ':' -> True
  ';' -> True
  '?' -> True
  '{' -> True
  '}' -> True
  '–' -> True
  '—' -> True
  _   -> False

isTransparent :: Char -> Bool
isTransparent x = Char.isSpace x || isTransparentPunctuation x

nes :: a -> NonEmpty a
nes a = a :| []

assembleCodeBlock :: Pos -> [Text] -> Text
assembleCodeBlock indent ls = T.unlines (stripIndent indent <$> ls)

assembleParagraph :: Pos -> [Text] -> Text -- TODO strip '>' here properly
assembleParagraph _ = go
  where
    go []     = ""
    go [x]    = T.dropWhileEnd isSpace x
    go (x:xs) = x <> "\n" <> go xs

indentLevel :: Text -> Int
indentLevel = T.foldl' f 0 . T.takeWhile isSpace
  where
    f n ch
      | ch == ' '  = n + 1
      | ch == '\t' = n + 4
      | otherwise  = n

stripIndent :: Pos -> Text -> Text
stripIndent indent txt = T.drop m txt
  where
    m = snd $ T.foldl' f (0, 0) (T.takeWhile p txt)
    p x = isSpace x || x == '>'
    f (!j, !n) ch
      | j  >= i    = (j, n)
      | ch == ' '  = (j + 1, n + 1)
      | ch == '\t' = (j + 4, n + 1)
      | otherwise  = (j, n)
    i = unPos indent - 1

collapseWhiteSpace :: Text -> Text
collapseWhiteSpace =
  T.stripEnd . T.filter (/= '\0') . snd . T.mapAccumL f True
  where
    f seenSpace ch =
      case (seenSpace, g ch) of
        (False, False) -> (False, ch)
        (True,  False) -> (False, ch)
        (False, True)  -> (True,  ' ')
        (True,  True)  -> (True,  '\0')
    g ' '  = True
    g '\t' = True
    g '\n' = True
    g _    = False

inlineFrameDel :: InlineFrame -> Text
inlineFrameDel = \case
  EmphasisFrame    -> "*"
  EmphasisFrame_   -> "_"
  StrongFrame      -> "**"
  StrongFrame_     -> "__"
  StrikeoutFrame   -> "~~"
  SubscriptFrame   -> "~"
  SuperscriptFrame -> "^"

inlineStateDel :: InlineState -> Text
inlineStateDel = \case
  SingleFrame x   -> inlineFrameDel x
  DoubleFrame x y -> inlineFrameDel x <> inlineFrameDel y

liftFrame :: InlineFrame -> NonEmpty Inline -> Inline
liftFrame = \case
  StrongFrame      -> Strong
  EmphasisFrame    -> Emphasis
  StrongFrame_     -> Strong
  EmphasisFrame_   -> Emphasis
  StrikeoutFrame   -> Strikeout
  SubscriptFrame   -> Subscript
  SuperscriptFrame -> Superscript

replaceEof :: String -> ParseError Char e -> ParseError Char e
replaceEof altLabel = \case
  TrivialError pos us es -> TrivialError pos (f <$> us) (E.map f es)
  FancyError   pos xs    -> FancyError pos xs
  where
    f EndOfInput = Label (NE.fromList altLabel)
    f x          = x

mmarkErr :: MonadParsec MMarkErr s m => MMarkErr -> m a
mmarkErr = fancyFailure . E.singleton . ErrorCustom

toNesTokens :: Text -> NonEmpty Char
toNesTokens = NE.fromList . T.unpack

isEmailUri :: URI -> Maybe Text
isEmailUri uri =
  case URI.unRText <$> URI.uriPath uri of
    [x] ->
      if Email.isValid (TE.encodeUtf8 x) &&
          (isNothing (URI.uriScheme uri) ||
           URI.uriScheme uri == Just mailtoScheme)
        then Just x
        else Nothing
    _ -> Nothing

mailtoScheme :: URI.RText 'URI.Scheme
mailtoScheme = fromJust (URI.mkScheme "mailto")

splitYamlError :: FilePath -> String -> (Maybe SourcePos, String)
splitYamlError file str = maybe (Nothing, str) (first pure) (parseMaybe p str)
  where
    p :: Parsec Void String (SourcePos, String)
    p = do
      void (string "YAML parse exception at line ")
      l <- mkPos . (+ 2) <$> L.decimal
      void (string ", column ")
      c <- mkPos . (+ 1) <$> L.decimal
      void (string ":\n")
      r <- takeRest
      return (SourcePos file l c, r)
