-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

-- | Gives information about symbols at a given point in DAML files.
-- These are all pure functions that should execute quickly.
module Development.IDE.Spans.AtPoint (
    atPoint
  , gotoDefinition
  , gotoTypeDefinition
  ) where

import           Development.IDE.GHC.Error
import Development.IDE.GHC.Orphans()
import Development.IDE.Types.Location

-- DAML compiler and infrastructure
import Development.IDE.GHC.Compat
import Development.IDE.Types.Options
import Development.IDE.Spans.Type as SpanInfo
import Development.IDE.Spans.Common (showName, spanDocToMarkdown)

-- GHC API imports
import FastString
import Name
import Outputable hiding ((<>))
import SrcLoc
import Type
import VarSet

import Control.Monad.Extra
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Class
import Control.Monad.IO.Class
import           Data.Maybe
import           Data.List
import qualified Data.Text as T

gotoTypeDefinition
  :: MonadIO m
  => (Module -> MaybeT m (HieFile, FilePath))
  -> IdeOptions
  -> [SpanInfo]
  -> Position
  -> MaybeT m [Location]
gotoTypeDefinition getHieFile ideOpts srcSpans pos
  = typeLocationsAtPoint getHieFile ideOpts pos srcSpans

-- | Locate the definition of the name at a given position.
gotoDefinition
  :: MonadIO m
  => (Module -> MaybeT m (HieFile, FilePath))
  -> IdeOptions
  -> [SpanInfo]
  -> Position
  -> MaybeT m Location
gotoDefinition getHieFile ideOpts srcSpans pos =
  MaybeT . pure . listToMaybe =<< locationsAtPoint getHieFile ideOpts pos srcSpans

-- | Synopsis for the name at a given position.
atPoint
  :: IdeOptions
  -> SpansInfo
  -> Position
  -> Maybe (Maybe Range, [T.Text])
atPoint IdeOptions{..} (SpansInfo srcSpans cntsSpans) pos = do
    firstSpan <- listToMaybe $ deEmpasizeGeneratedEqShow $ spansAtPoint pos srcSpans
    let constraintsAtPoint = mapMaybe spaninfoType (spansAtPoint pos cntsSpans)
        -- Filter out the empty lines so we don't end up with a bunch of
        -- horizontal separators with nothing inside of them
        text = filter (not . T.null) $ hoverInfo firstSpan constraintsAtPoint
    return (Just (range firstSpan), text)
  where
    -- Hover info for types, classes, type variables
    hoverInfo SpanInfo{spaninfoType = Nothing , spaninfoDocs = docs ,  ..} _ =
       (wrapLanguageSyntax <$> name) <> location <> spanDocToMarkdown docs
     where
       name     = [maybe shouldNotHappen showName  mbName]
       location = [maybe shouldNotHappen definedAt mbName]
       shouldNotHappen = "ghcide: did not expect a type level component without a name"
       mbName = getNameM spaninfoSource

    -- Hover info for values/data
    hoverInfo SpanInfo{spaninfoType = (Just typ), spaninfoDocs = docs , ..} cnts =
       (wrapLanguageSyntax <$> nameOrSource) <> location <> spanDocToMarkdown docs
     where
       mbName = getNameM spaninfoSource
       expr = case spaninfoSource of
                Named n -> qualifyNameIfPossible n
                Lit   l -> crop $ T.pack l
                _       -> ""
       nameOrSource   = [expr <> "\n" <> typeAnnotation]
       qualifyNameIfPossible name' = modulePrefix <> showName name'
         where modulePrefix = maybe "" (<> ".") (getModuleNameAsText name')
       location = [maybe "" definedAt mbName]

       thisFVs = tyCoVarsOfType typ
       constraintsOverFVs = filter (\cnt -> not (tyCoVarsOfType cnt `disjointVarSet` thisFVs)) cnts
       constraintsT = T.intercalate ", " (map showName constraintsOverFVs)

       typeAnnotation = case constraintsOverFVs of
                          []  -> colon <> showName typ
                          [_] -> colon <> constraintsT <> "\n=> " <> showName typ
                          _   -> colon <> "(" <> constraintsT <> ")\n=> " <> showName typ

    definedAt name = "*Defined " <> T.pack (showSDocUnsafe $ pprNameDefnLoc name) <> "*\n"

    crop txt
      | T.length txt > 50 = T.take 46 txt <> " ..."
      | otherwise         = txt

    range SpanInfo{..} = Range
      (Position spaninfoStartLine spaninfoStartCol)
      (Position spaninfoEndLine spaninfoEndCol)

    colon = if optNewColonConvention then ": " else ":: "
    wrapLanguageSyntax x = T.unlines [ "```" <> T.pack optLanguageSyntax, x, "```"]

    -- NOTE(RJR): This is a bit hacky.
    -- We don't want to show the user type signatures generated from Eq and Show
    -- instances, as they do not appear in the source program.
    -- However the user could have written an `==` or `show` function directly,
    -- in which case we still want to show information for that.
    -- Hence we just move such information later in the list of spans.
    deEmpasizeGeneratedEqShow :: [SpanInfo] -> [SpanInfo]
    deEmpasizeGeneratedEqShow = uncurry (++) . partition (not . isTypeclassDeclSpan)
    isTypeclassDeclSpan :: SpanInfo -> Bool
    isTypeclassDeclSpan spanInfo =
      case getNameM (spaninfoSource spanInfo) of
        Just name -> any (`isInfixOf` getOccString name) ["==", "showsPrec"]
        Nothing -> False



typeLocationsAtPoint
  :: forall m
   . MonadIO m
  => (Module -> MaybeT m (HieFile, FilePath))
  -> IdeOptions
  -> Position
  -> [SpanInfo]
  -> MaybeT m [Location]
typeLocationsAtPoint getHieFile = querySpanInfoAt getTypeSpan
  where getTypeSpan :: SpanInfo -> m (Maybe SrcSpan)
        getTypeSpan SpanInfo { spaninfoType = Just t } =
          case splitTyConApp_maybe t of
            Nothing -> return Nothing
            Just (getName -> name, _) ->
              nameToLocation getHieFile name
        getTypeSpan _ = return Nothing

locationsAtPoint
  :: forall m
   . MonadIO m
  => (Module -> MaybeT m (HieFile, FilePath))
  -> IdeOptions
  -> Position
  -> [SpanInfo]
  -> MaybeT m [Location]
locationsAtPoint getHieFile = querySpanInfoAt (getSpan . spaninfoSource)
  where getSpan :: SpanSource -> m (Maybe SrcSpan)
        getSpan NoSource = pure Nothing
        getSpan (SpanS sp) = pure $ Just sp
        getSpan (Lit _) = pure Nothing
        getSpan (Named name) = nameToLocation getHieFile name

querySpanInfoAt :: forall m
   . MonadIO m
  => (SpanInfo -> m (Maybe SrcSpan))
  -> IdeOptions
  -> Position
  -> [SpanInfo]
  -> MaybeT m [Location]
querySpanInfoAt getSpan _ideOptions pos =
    lift . fmap (map srcSpanToLocation) . mapMaybeM getSpan . spansAtPoint pos

-- | Given a 'Name' attempt to find the location where it is defined.
nameToLocation :: Monad f => (Module -> MaybeT f (HieFile, String)) -> Name -> f (Maybe SrcSpan)
nameToLocation getHieFile name =
  case nameSrcSpan name of
    sp@(RealSrcSpan _) -> pure $ Just sp
    sp@(UnhelpfulSpan _) -> runMaybeT $ do
      guard (sp /= wiredInSrcSpan)
      -- This case usually arises when the definition is in an external package (DAML only).
      -- In this case the interface files contain garbage source spans
      -- so we instead read the .hie files to get useful source spans.
      mod <- MaybeT $ return $ nameModule_maybe name
      (hieFile, srcPath) <- getHieFile mod
      avail <- MaybeT $ pure $ find (eqName name . snd) $ hieExportNames hieFile
      -- The location will point to the source file used during compilation.
      -- This file might no longer exists and even if it does the path will be relative
      -- to the compilation directory which we don’t know.
      let span = setFileName srcPath $ fst avail
      pure span
  where
    -- We ignore uniques and source spans and only compare the name and the module.
    eqName :: Name -> Name -> Bool
    eqName n n' = nameOccName n == nameOccName n' && nameModule_maybe n == nameModule_maybe n'
    setFileName f (RealSrcSpan span) = RealSrcSpan (span { srcSpanFile = mkFastString f })
    setFileName _ span@(UnhelpfulSpan _) = span

-- | Filter out spans which do not enclose a given point
spansAtPoint :: Position -> [SpanInfo] -> [SpanInfo]
spansAtPoint pos = filter atp where
  line = _line pos
  cha = _character pos
  atp SpanInfo{..} =
      startsBeforePosition && endsAfterPosition
    where
      startLineCmp = compare spaninfoStartLine line
      endLineCmp   = compare spaninfoEndLine   line

      startsBeforePosition = startLineCmp == LT || (startLineCmp == EQ && spaninfoStartCol <= cha)
                                              -- The end col points to the column after the
                                              -- last character so we use > instead of >=
      endsAfterPosition = endLineCmp == GT || (endLineCmp == EQ && spaninfoEndCol > cha)


getModuleNameAsText :: Name -> Maybe T.Text
getModuleNameAsText n = do
  m <- nameModule_maybe n
  return . T.pack . moduleNameString $ moduleName m
