module VK.AssignModules
  ( assignModules
  ) where

import           Relude                  hiding ( runState
                                                , execState
                                                , evalState
                                                , State
                                                , modify'
                                                , ask
                                                , get
                                                , put
                                                , gets
                                                )
import           Data.Vector                    ( Vector )
import qualified Data.Vector.Extra             as V
import           Data.Version
import qualified Data.List.Extra               as List
import qualified Data.Map                      as Map
import qualified Data.IntMap.Strict            as IntMap
import qualified Data.IntSet                   as Set
import qualified Data.Set
import qualified Data.Text.Extra               as T
import           Polysemy
import           Polysemy.Input
import           Polysemy.State
import           Algebra.Graph.AdjacencyIntMap
                                         hiding ( empty )

import           Error
import           Haskell
import           Render.Element
import           Render.SpecInfo
import           Spec.Types
import           VkModulePrefix

import           VK.Render

-- | Assign all render elements a module
assignModules
  :: forall r
   . (HasErr r, HasRenderParams r, HasSpecInfo r)
  => Spec
  -> RenderedSpec RenderElement
  -> Sem r [(ModName, Vector RenderElement)]
assignModules spec@Spec {..} rs@RenderedSpec {..} = do
  RenderParams {..} <- input
  let indexed = run . evalState (0 :: Int) $ traverse
        (\r -> do
          i <- get @Int
          modify' @Int succ
          pure (i, r)
        )
        rs
      flat = fromList . toList $ indexed
      lookupRe i = case flat V.!? i of
        Nothing     -> throw "Unable to find element at index"
        Just (_, e) -> pure e
  (exporterMap, rel) <- buildRelation (fromList . toList $ indexed)
  let getExporter n =
        note ("Unable to find " <> show n <> " in any render element")
          $ Map.lookup n exporterMap
      initialState = mempty :: S

  exports <- execState initialState
    $ assign (raise . getExporter) rel (closure rel) spec indexed

  --
  -- Check that everything is exported
  --
  unexportedNames <- unexportedNames spec
  forV_ indexed $ \(i, re) -> case IntMap.lookup i exports of
    Nothing -> do
      let exportedNames = exportName <$> toList (reExports re)
      forV_ (List.nubOrd exportedNames List.\\ unexportedNames)
        $ \n -> throw $ show n <> " is not exported from any module"
    Just _ -> pure ()

  let declaredNames = Map.fromListWith
        (<>)
        (   IntMap.toList exports
        <&> \(n, ExportLocation d _) -> (d, Set.singleton n)
        )
      reexportingMap = Map.fromListWith
        (<>)
        [ (m, Set.singleton n)
        | (n, ExportLocation _ ms) <- IntMap.toList exports
        , m                        <- toList ms
        ]

  forV (Map.toList declaredNames) $ \(modname, is) -> do
    declaringRenderElements   <- traverseV lookupRe (fromList (Set.toList is))
    reexportingRenderElements <- case Map.lookup modname reexportingMap of
      Nothing -> pure mempty
      Just is -> do
        res <-
          filter (getAll . reReexportable) <$> forV (Set.toList is) lookupRe
        pure
          $ (reexportingRenderElement . Data.Set.fromList . toList . reExports)
          <$> res
    pure
      (modname, declaringRenderElements <> fromList reexportingRenderElements)

reexportingRenderElement :: Data.Set.Set Export -> RenderElement
reexportingRenderElement exports =
  (emptyRenderElement ("reexporting " <> show exports))
    { reReexportedNames = Data.Set.filter
                            ((== Reexportable) . exportReexportable)
                            exports
    }

data ExportLocation = ExportLocation
  { _elDeclaringModule    :: ModName
  , _elReExportingModules :: [ModName]
  }

type S = IntMap ExportLocation

data ReqDeps = ReqDeps
  { commands        :: Vector Int
  , types           :: Vector Int
  , enumValues      :: Vector Int
  , directExporters :: Vector Int
    -- ^ The union of all the above
  }


-- The type is put into the first rule that applies, and reexported from any
-- subsequent matching rules in that feature.
--
-- - For each feature
--   - All reachable enums are put under the Feature.Enums module
--   - Commands are put into their respective components
--   - All types directly used by a command are put into the same module
--
-- - For each extension
--   -
assign
  :: forall r
   . (HasErr r, Member (State S) r, HasRenderParams r)
  => (HName -> Sem r Int)
  -> AdjacencyIntMap
  -> AdjacencyIntMap
  -> Spec
  -> RenderedSpec (Int, RenderElement)
  -> Sem r ()
assign getExporter rel closedRel Spec {..} rs@RenderedSpec {..} = do
  RenderParams {..} <- input

  let
    allEnums        = IntMap.fromList (toList rsEnums)
    allHandles      = IntMap.fromList (toList rsHandles)
    allFuncPointers = IntMap.fromList (toList rsFuncPointers)
    -- Handy for debugging
    _elemName       = let l = toList rs in \i -> reName <$> List.lookup i l

    --
    -- Perform an action over all Features
    --
    forFeatures
      :: (Feature -> Text -> (Maybe Text -> ModName) -> Sem r a)
      -> Sem r (Vector a)
    forFeatures f = forV specFeatures $ \feat@Feature {..} -> do
      let
        prefix = vulkanModulePrefix <> ".Core" <> foldMap
          show
          (versionBranch fVersion)
      f feat prefix (featureCommentToModuleName prefix)
    forFeatures_ = void . forFeatures

    forExtensionRequires
      :: (Text -> ModName -> ReqDeps -> Require -> Sem r ()) -> Sem r ()
    forExtensionRequires f = forV_ specExtensions $ \Extension {..} ->
      forRequires_ exRequires (const $ extensionNameToModuleName exName)
        $ \modname -> f extensionModulePrefix modname

    forRequires
      :: Traversable f
      => f Require
      -> (Maybe Text -> ModName)
      -> (ModName -> ReqDeps -> Require -> Sem r a)
      -> Sem r [a]
    forRequires requires commentToModName f =
      forV (sortOn (isNothing . rComment) . toList $ requires) $ \r -> do
        commands   <- traverseV (getExporter . mkFunName) (rCommandNames r)
        types      <- traverseV (getExporter . mkTyName) (rTypeNames r)
        enumValues <- traverseV (getExporter . mkPatternName)
                                (rEnumValueNames r)
        let directExporters = commands <> types <> enumValues
        f (commentToModName (rComment r)) ReqDeps { .. } r

    forRequires_ requires commentToModName =
      void . forRequires requires commentToModName

    --
    -- Perform an action over all 'Require's of all features and elements
    --
    forFeaturesAndExtensions
      :: (Text -> ModName -> Bool -> ReqDeps -> Require -> Sem r ()) -> Sem r ()
    forFeaturesAndExtensions f = do
      forFeatures_ $ \feat prefix commentToModName ->
        forRequires_ (fRequires feat) commentToModName
          $ \modname -> f prefix modname True
      forExtensionRequires $ \prefix modname -> f prefix modname False

    --
    -- Export all elements both in world and reachable, optionally from a
    -- specifically named submodule.
    --
    exportReachable
      :: Bool -> Text -> IntMap RenderElement -> IntSet -> Sem r ()
    exportReachable namedSubmodule prefix world reachable = do
      let reachableWorld = world `IntMap.restrictKeys` reachable
      forV_ (IntMap.toList reachableWorld) $ \(i, re) -> do
        modName <- if namedSubmodule
          then do
            name <- firstTypeName re
            pure (ModName (prefix <> "." <> name))
          else pure (ModName prefix)
        export modName i

  allCoreExports <-
    fmap (Set.unions . concat . toList)
    . forFeatures
    $ \Feature {..} _ mkName ->
        forRequires fRequires mkName $ \_ ReqDeps {..} _ ->
          let direct = Set.fromList (toList directExporters)
          in  pure $ direct `postIntSets` closedRel

  ----------------------------------------------------------------
  -- Explicit elements
  ----------------------------------------------------------------
  forV_ rs $ \(i, re) -> forV_ (reExplicitModule re) $ \m -> export m i

  ----------------------------------------------------------------
  -- API Constants
  ----------------------------------------------------------------
  let constantModule = vulkanModule ["Core10", "APIConstants"]
  forV_ rsAPIConstants $ \(i, _) -> export constantModule i

  ----------------------------------------------------------------
  -- Explicit Enums, Handles and FuncPointers for each feature
  ----------------------------------------------------------------

  forFeaturesAndExtensions $ \prefix _ isFeature ReqDeps {..} _ -> do
    let reachable =
          Set.unions . toList $ (`postIntSet` closedRel) <$> directExporters
    ----------------------------------------------------------------
    -- Reachable Enums
    ----------------------------------------------------------------
    when isFeature
      $ exportReachable True (prefix <> ".Enums") allEnums reachable

    ----------------------------------------------------------------
    -- Reachable Handles
    ----------------------------------------------------------------
    exportReachable False (prefix <> ".Handles") allHandles reachable

    ----------------------------------------------------------------
    -- Reachable FuncPointers
    ----------------------------------------------------------------
    when isFeature $ exportReachable False
                                     (prefix <> ".FuncPointers")
                                     allFuncPointers
                                     reachable

  ----------------------------------------------------------------
  -- Explicit exports of all features and extensions
  ----------------------------------------------------------------
  forFeaturesAndExtensions $ \_ modname isFeature ReqDeps {..} _ -> if isFeature
    then forV_ directExporters $ export modname
    else
      let noCore = Set.toList
            (                Set.fromList (toList directExporters)
            `Set.difference` allCoreExports
            )
      in  forV_ noCore $ export modname

  ----------------------------------------------------------------
  -- Assign aliases to be with their targets if they're not already assigned
  ----------------------------------------------------------------
  forV_ specAliases $ \Alias {..} -> do
    let mkName = case aType of
          TypeAlias    -> mkTyName
          TermAlias    -> mkFunName -- TODO, terms other than functions?
          PatternAlias -> mkPatternName
    i <- getExporter (mkName aName)
    j <- getExporter (mkName aTarget)
    gets @S (IntMap.lookup i) >>= \case
      Just _  -> pure ()
      Nothing -> gets @S (IntMap.lookup j) >>= \case
        Just (ExportLocation jMod _) ->
          modify' (IntMap.insert i (ExportLocation jMod []))
        Nothing -> pure ()

  ----------------------------------------------------------------
  -- Go over the features one by one and close them
  ----------------------------------------------------------------

  forFeatures_ $ \feat _ getModName -> do
    -- Types directly referred to by the commands and types
    forRequires_ (fRequires feat) getModName $ \modname ReqDeps {..} _ ->
      forV_ directExporters
        $ \i -> exportManyNoReexport modname (i `postIntSet` rel)
    -- Types indirectly referred to by the commands and types
    forRequires_ (fRequires feat) getModName $ \modname ReqDeps {..} _ ->
      forV_ directExporters
        $ \i -> exportManyNoReexport modname (i `postIntSet` closedRel)

  ----------------------------------------------------------------
  -- Close the extensions
  ----------------------------------------------------------------
  forExtensionRequires $ \_ modname ReqDeps {..} _ ->
    forV_ directExporters $ \i -> do
      exportManyNoReexport modname (i `postIntSet` rel)
      exportMany modname ((i `postIntSet` rel) `Set.difference` allCoreExports)

  forExtensionRequires $ \_ modname ReqDeps {..} _ ->
    forV_ directExporters $ \i -> exportMany
      modname
      ((i `postIntSet` closedRel) `Set.difference` allCoreExports)


firstTypeName :: HasErr r => RenderElement -> Sem r Text
firstTypeName re =
  case V.mapMaybe getTyConName (exportName <$> reExports re) of
    V.Empty   -> throw "Unable to get type name from RenderElement"
    x V.:<| _ -> pure x

export :: Member (State S) r => ModName -> Int -> Sem r ()
export m i = modify' (IntMap.alter ins i)
 where
  ins = \case
    Nothing                    -> Just (ExportLocation m [])
    Just (ExportLocation t rs) -> Just (ExportLocation t (m : rs))

exportMany :: Member (State S) r => ModName -> IntSet -> Sem r ()
exportMany m is =
  let newMap = IntMap.fromSet (const (ExportLocation m [])) is
  in  modify' (\s -> IntMap.unionWith ins s newMap)
 where
  ins (ExportLocation r rs) (ExportLocation n _) = ExportLocation r (n : rs)

exportManyNoReexport :: Member (State S) r => ModName -> IntSet -> Sem r ()
exportManyNoReexport m is =
  let newMap = IntMap.fromSet (const (ExportLocation m [])) is
  in  modify' (\s -> IntMap.unionWith ins s newMap)
  where ins (ExportLocation r rs) (ExportLocation _ _) = ExportLocation r rs

----------------------------------------------------------------
-- Making module names
----------------------------------------------------------------

extensionModulePrefix :: Text
extensionModulePrefix = vulkanModulePrefix <> ".Extensions"

extensionNameToModuleName :: Text -> ModName
extensionNameToModuleName = ModName . ((extensionModulePrefix <> ".") <>)

featureCommentToModuleName :: Text -> Maybe Text -> ModName
featureCommentToModuleName prefix = \case
  Nothing -> ModName prefix
  Just t ->
    ModName
      $ ((prefix <> ".") <>)
      . mconcat
      . fmap (T.upperCaseFirst . replaceSymbols)
      . dropLast "API"
      . dropLast "commands"
      . T.words
      . T.replace "Promoted from" "Promoted_From_"
      . T.replace "Originally based on" "Originally_Based_On_"
      . T.takeWhile (/= ',')
      . removeParens
      . featureCommentMap
      $ t

featureCommentMap :: Text -> Text
featureCommentMap = \case
  "These types are part of the API and should always be defined, even when no enabled features require them."
    -> "OtherTypes"
  t -> t

----------------------------------------------------------------
-- Utils
----------------------------------------------------------------

buildRelation
  :: HasErr r
  => Vector (Int, RenderElement)
  -> Sem r (Map HName Int, AdjacencyIntMap)
buildRelation elements = do
  let elementExports RenderElement {..} =
        reInternal <> reExports <> V.concatMap exportWith reExports
      elementImports =
        fmap importName . filter (not . importSource) . toList . reLocalImports
      numbered = elements
      allNames = sortOn
        fst
        [ (n, i)
        | (i, x) <- toList numbered
        , n <- fmap exportName . V.toList . elementExports $ x
        ]
      nameMap = Map.fromAscList allNames
      lookup n = case Map.lookup n nameMap of
        Nothing -> pure 0 -- throw $ "Unable to find " <> show n <> " in any vertex"
        Just i  -> pure i

  es <- concat
    <$> forV numbered (\(n, x) -> forV (elementImports x) (fmap (n, ) . lookup))

  let relation = vertices (fst <$> toList numbered) `overlay` edges es

  pure (nameMap, relation)

getTyConName :: HName -> Maybe Text
getTyConName = \case
  TyConName n -> Just n
  _ -> Nothing

removeParens :: Text -> Text
removeParens t =
  let (x, y) = T.breakOn "(" t in x <> T.takeWhileEnd (/= ')') y

replaceSymbols :: Text -> Text
replaceSymbols = \case
  "+" -> "And"
  t   -> t

dropLast :: Eq a => a -> [a] -> [a]
dropLast x l = case nonEmpty l of
  Nothing -> []
  Just xs -> if last xs == x then init xs else toList xs

postIntSets :: IntSet -> AdjacencyIntMap -> IntSet
postIntSets is rel = Set.unions $ (`postIntSet` rel) <$> Set.toList is

----------------------------------------------------------------
-- Ignored unexported names
----------------------------------------------------------------

unexportedNames :: HasRenderParams r => Spec -> Sem r [HName]
unexportedNames Spec {..} = do
  RenderParams {..} <- input
  let apiVersions = toList specFeatures <&> \Feature {..} ->
        let major : minor : _ = versionBranch fVersion
        in  mkTyName
              (CName $ "VK_API_VERSION_" <> show major <> "_" <> show minor)
  pure
    $  [ mkFunName "vkGetSwapchainGrallocUsageANDROID"
       , mkFunName "vkGetSwapchainGrallocUsage2ANDROID"
       , mkFunName "vkAcquireImageANDROID"
       , mkFunName "vkQueueSignalReleaseImageANDROID"
       , mkTyName "VkSwapchainImageUsageFlagBitsANDROID"
       , mkTyName "VkSwapchainImageUsageFlagsANDROID"
       , mkTyName "VkNativeBufferUsage2ANDROID"
       , mkTyName "VkNativeBufferANDROID"
       , mkTyName "VkSwapchainImageCreateInfoANDROID"
       , mkTyName "VkPhysicalDevicePresentationPropertiesANDROID"
         -- TODO: Export these
       , mkTyName "VkSemaphoreCreateFlagBits"
       ]
    <> apiVersions

