{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

-- | Random utilities used by the code.
module Ormolu.Utils
  ( RelativePos (..),
    attachRelativePos,
    combineSrcSpans',
    notImplemented,
    showOutputable,
    splitDocString,
    incSpanLine,
    separatedByBlank,
    separatedByBlankNE,
    onTheSameLine,
    groupBy',
    HasSrcSpan (..),
    getLoc',
    matchAddEpAnn,
  )
where

import Data.List (dropWhileEnd)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified GHC.Data.Strict as Strict
import GHC.Driver.Ppr
import GHC.DynFlags (baseDynFlags)
import GHC.Hs
import GHC.Types.SrcLoc
import GHC.Utils.Outputable

-- | Relative positions in a list.
data RelativePos
  = SinglePos
  | FirstPos
  | MiddlePos
  | LastPos
  | FirstAfterDocPos
  deriving (Eq, Show)

-- | Attach 'RelativePos'es to elements of a given list.
attachRelativePos :: [a] -> [(RelativePos, a)]
attachRelativePos = \case
  [] -> []
  [x] -> [(SinglePos, x)]
  (x : xs) -> (FirstPos, x) : markLast xs
  where
    markLast [] = []
    markLast [x] = [(LastPos, x)]
    markLast (x : xs) = (MiddlePos, x) : markLast xs

-- | Combine all source spans from the given list.
combineSrcSpans' :: NonEmpty SrcSpan -> SrcSpan
combineSrcSpans' (x :| xs) = foldr combineSrcSpans x xs

-- | Placeholder for things that are not yet implemented.
notImplemented :: String -> a
notImplemented msg = error $ "not implemented yet: " ++ msg

-- | Pretty-print an 'GHC.Outputable' thing.
showOutputable :: Outputable o => o -> String
showOutputable = showSDoc baseDynFlags . ppr

-- | Split and normalize a doc string. The result is a list of lines that
-- make up the comment.
splitDocString :: HsDocString -> [Text]
splitDocString docStr =
  case r of
    [] -> [""]
    _ -> r
  where
    r =
      fmap (escapeLeadingDollar . escapeCommentBraces)
        . dropWhileEnd T.null
        . fmap (T.stripEnd . T.pack)
        . lines
        $ renderHsDocString docStr
    -- We cannot have the first character to be a dollar because in that
    -- case it'll be a parse error (apparently collides with named docs
    -- syntax @-- $name@ somehow).
    escapeLeadingDollar txt =
      case T.uncons txt of
        Just ('$', _) -> T.cons '\\' txt
        _ -> txt
    escapeCommentBraces = T.replace "{-" "{\\-" . T.replace "-}" "-\\}"

-- | Increment line number in a 'SrcSpan'.
incSpanLine :: Int -> SrcSpan -> SrcSpan
incSpanLine i = \case
  RealSrcSpan s _ ->
    let start = realSrcSpanStart s
        end = realSrcSpanEnd s
        incLine x =
          let file = srcLocFile x
              line = srcLocLine x
              col = srcLocCol x
           in mkRealSrcLoc file (line + i) col
     in RealSrcSpan (mkRealSrcSpan (incLine start) (incLine end)) Strict.Nothing
  UnhelpfulSpan x -> UnhelpfulSpan x

-- | Do two declarations have a blank between them?
separatedByBlank :: (a -> SrcSpan) -> a -> a -> Bool
separatedByBlank loc a b =
  fromMaybe False $ do
    endA <- srcSpanEndLine <$> srcSpanToRealSrcSpan (loc a)
    startB <- srcSpanStartLine <$> srcSpanToRealSrcSpan (loc b)
    pure (startB - endA >= 2)

-- | Do two declaration groups have a blank between them?
separatedByBlankNE :: (a -> SrcSpan) -> NonEmpty a -> NonEmpty a -> Bool
separatedByBlankNE loc a b = separatedByBlank loc (NE.last a) (NE.head b)

-- | Return 'True' if one span ends on the same line the second one starts.
onTheSameLine :: SrcSpan -> SrcSpan -> Bool
onTheSameLine a b =
  isOneLineSpan (mkSrcSpan (srcSpanEnd a) (srcSpanStart b))

-- | A generalisation of 'groupBy' to functions which aren't equivalences - a group ends
-- when comparison fails with the previous element, rather than the first of the group.
groupBy' :: (a -> a -> Bool) -> [a] -> [NonEmpty a]
groupBy' eq = flip foldr [] $ \x -> \case
  [] -> [pure x]
  (y :| ys) : zs ->
    if x `eq` y
      then (x :| y : ys) : zs
      else pure x : (y :| ys) : zs

class HasSrcSpan l where
  loc' :: l -> SrcSpan

instance HasSrcSpan SrcSpan where
  loc' = id

instance HasSrcSpan (SrcSpanAnn' ann) where
  loc' = locA

getLoc' :: HasSrcSpan l => GenLocated l a -> SrcSpan
getLoc' = loc' . getLoc

-- | Check whether the given 'AnnKeywordId' or its Unicode variant is in an
-- 'AddEpAnn', and return the 'EpaLocation' if so.
matchAddEpAnn :: AnnKeywordId -> AddEpAnn -> Maybe EpaLocation
matchAddEpAnn annId (AddEpAnn annId' loc)
  | annId == annId' || unicodeAnn annId == annId' = Just loc
  | otherwise = Nothing
