-- Copyright (c) Facebook, Inc. and its affiliates.
--
-- This source code is licensed under the MIT license found in the
-- LICENSE file in the root directory of this source tree.
--
{-# LANGUAGE CPP #-}
{-# LANGUAGE TupleSections #-}
module Retrie.Rewrites.Function
  ( dfnsToRewrites
  , getImports
  , matchToRewrites
  ) where

import Control.Monad
import Control.Monad.State.Lazy
import Data.List
import Data.Maybe
import Data.Traversable

import Retrie.ExactPrint
import Retrie.Expr
import Retrie.GHC
import Retrie.Quantifiers
import Retrie.Types
import Retrie.Util

dfnsToRewrites
  :: LibDir
  -> [(FastString, Direction)]
  -> AnnotatedModule
  -> IO (UniqFM FastString [Rewrite (LHsExpr GhcPs)])
dfnsToRewrites libdir specs am = fmap astA $ transformA am $ \ (L _ m) -> do
  let
    fsMap = uniqBag specs

  rrs <- sequence
    [ do
        fe <- mkLocatedHsVar fRdrName
        -- lift $ debugPrint Loud "dfnsToRewrites:ef="  [showAst fe]
        imps <- getImports libdir dir (hsmodName m)
        (fName,) . concat <$>
          forM (unLoc $ mg_alts $ fun_matches f) (matchToRewrites fe imps dir)
    | L _ (ValD _ f@FunBind{}) <- hsmodDecls m
    , let fRdrName = fun_id f
    , let fName = occNameFS (occName (unLoc fRdrName))
    , dir <- fromMaybe [] (lookupUFM fsMap fName)
    ]

  return $ listToUFM_C (++) rrs

------------------------------------------------------------------------

getImports
  :: LibDir -> Direction -> Maybe (LocatedA ModuleName) -> TransformT IO AnnotatedImports
getImports libdir RightToLeft (Just (L _ mn)) = -- See Note [fold only]
  TransformT $ lift $ liftIO $ parseImports libdir ["import " ++ moduleNameString mn]
getImports _ _ _ = return mempty

matchToRewrites
  :: LHsExpr GhcPs
  -> AnnotatedImports
  -> Direction
  -> LMatch GhcPs (LHsExpr GhcPs)
  -> TransformT IO [Rewrite (LHsExpr GhcPs)]
matchToRewrites e imps dir (L _ alt) = do
  -- lift $ debugPrint Loud "matchToRewrites:e="  [showAst e]
  let
#if __GLASGOW_HASKELL__ >= 912
    L lp pats' = m_pats alt
    pats = case pats' of
             [] -> []
             (L (EpAnn _ an cs) h:t) -> L (EpAnn lp an cs) h:t
#else
    pats = m_pats alt
#endif
    grhss = m_grhss alt
  qss <- for (zip (inits pats) (tails pats)) $
    makeFunctionQuery e imps dir grhss mkApps
  qs <- backtickRules e imps dir grhss pats
  return $ qs ++ concat qss

type AppBuilder =
  LHsExpr GhcPs -> [LHsExpr GhcPs] -> TransformT IO (LHsExpr GhcPs)

irrefutablePat :: LPat GhcPs -> Bool
irrefutablePat = go . unLoc
  where
    go WildPat{} = True
    go VarPat{} = True
    go (LazyPat _ p) = irrefutablePat p
#if __GLASGOW_HASKELL__ <= 904 || __GLASGOW_HASKELL__ >= 912
    go (AsPat _ _ p) = irrefutablePat p
#else
    go (AsPat _ _ _ p) = irrefutablePat p
#endif
#if __GLASGOW_HASKELL__ >= 912
    go (ParPat _ p) = irrefutablePat p
#else
    go (ParPat _ _ p _) = irrefutablePat p
#endif
    go (BangPat _ p) = irrefutablePat p
    go _ = False

makeFunctionQuery
  :: LHsExpr GhcPs
  -> AnnotatedImports
  -> Direction
  -> GRHSs GhcPs (LHsExpr GhcPs)
  -> AppBuilder
  -> ([LPat GhcPs], [LPat GhcPs])
  -> TransformT IO [Rewrite (LHsExpr GhcPs)]
makeFunctionQuery e imps dir grhss mkAppFn (argpats, bndpats)
  | any (not . irrefutablePat) bndpats = return []
  | otherwise = do
    let
      GRHSs _ rhss lbs = grhss
      bs = collectPatsBinders CollNoDictBinders argpats
    -- See Note [Wildcards]
    (es,(_,bs')) <- runStateT (mapM patToExpr argpats) (wildSupply bs, bs)
    -- lift $ debugPrint Loud "makeFunctionQuery:bs'="  [showAst bs']
    -- lift $ debugPrint Loud "makeFunctionQuery:argpats="  [showAst argpats]
    -- lift $ debugPrint Loud "makeFunctionQuery:e="  [showAst e]
    -- lift $ debugPrint Loud "makeFunctionQuery:grhss="  [showAst grhss]
    -- lift $ debugPrint Loud "makeFunctionQuery:es="  [showAst es]
    lhs <- mkAppFn e es
    -- lift $ debugPrint Loud "makeFunctionQuery:lhs="  [showAst lhs]
    for rhss $ \ grhs -> do
      le <- mkLet lbs (grhsToExpr grhs)
      rhs <- mkLams bndpats le
      -- lift $ debugPrint Loud "makeFunctionQuery:rhs="  [showAst rhs]
      let
        (pat, temp) =
          case dir of
            LeftToRight -> (lhs,rhs)
            RightToLeft -> (rhs,lhs)
      p <- pruneA pat
      t <- pruneA temp
      return $ addRewriteImports imps $ mkRewrite (mkQs bs') p t

backtickRules
  :: LHsExpr GhcPs
  -> AnnotatedImports
  -> Direction
  -> GRHSs GhcPs (LHsExpr GhcPs)
  -> [LPat GhcPs]
  -> TransformT IO [Rewrite (LHsExpr GhcPs)]
backtickRules e imps dir@LeftToRight grhss ps@[p1, p2] = do
  let
    both, left, right :: AppBuilder
#if __GLASGOW_HASKELL__ >= 912
    both op [l, r] = mkLocA (SameLine 1) (OpApp NoExtField l op r)
    both _ _ = fail "backtickRules - both: impossible!"

    left op [l] = mkLocA (SameLine 1) (SectionL NoExtField l op)
    left _ _ = fail "backtickRules - left: impossible!"

    right op [r] = mkLocA (SameLine 1) (SectionR NoExtField op r)
    right _ _ = fail "backtickRules - right: impossible!"
#else
    both op [l, r] = mkLocA (SameLine 1) (OpApp noAnn l op r)
    both _ _ = fail "backtickRules - both: impossible!"

    left op [l] = mkLocA (SameLine 1) (SectionL noAnn l op)
    left _ _ = fail "backtickRules - left: impossible!"

    right op [r] = mkLocA (SameLine 1) (SectionR noAnn op r)
    right _ _ = fail "backtickRules - right: impossible!"
#endif
  qs <- makeFunctionQuery e imps dir grhss both (ps, [])
  qsl <- makeFunctionQuery e imps dir grhss left ([p1], [p2])
  qsr <- makeFunctionQuery e imps dir grhss right ([p2], [p1])
  return $ qs ++ qsl ++ qsr
backtickRules _ _ _ _ _ = return []

-- Note [fold only]
-- Currently we only generate imports for folds, because it is easy.
-- (We only need to add an import for the module defining the folded
-- function.) Generating the imports for unfolds will require some
-- sort of analysis with haskell-names and is a TODO.
