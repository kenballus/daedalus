{-# Language OverloadedStrings #-}
{-# Language ViewPatterns, PatternSynonyms #-}
{-# Language DeriveGeneric, DeriveAnyClass, DeriveFunctor #-}

module Daedalus.Core.Grammar where

import GHC.Generics          (Generic)
import Control.DeepSeq       (NFData)
import Data.Functor.Identity(Identity(..))
import Data.Functor.Const (Const(Const))

import Daedalus.PP
import Daedalus.Core.Basics
import Daedalus.Core.Expr
import Daedalus.Core.ByteSet

data Grammar =
    Pure Expr
  | GetStream
  | SetStream Expr
  | Match Sem Match
  | Fail ErrorSource Type (Maybe Expr)
  | Do_ Grammar Grammar
  | Do  Name Grammar Grammar
  | Let Name Expr Grammar
  | OrBiased Grammar Grammar
  | OrUnbiased Grammar Grammar
  | Call FName [Expr]
  | Annot Annot Grammar
  | GCase (Case Grammar)
  | Loop (LoopClass Grammar)
  deriving (Generic,NFData)

-- | Types of loops we support.
data LoopClass' e body =
    ManyLoop Sem Backtrack e (Maybe e) body
    -- ^ `Many`

  | RepeatLoop Backtrack Name e body
    -- ^ `many`

  | MorphismLoop (LoopMorphism' e body)
    -- ^ `for`, `map`
  deriving (Functor, Generic, NFData)

type LoopClass = LoopClass' Expr

loopClassBody :: LoopClass' e body -> body
loopClassBody lc = case lc of
  ManyLoop _ _ _ _ g -> g
  RepeatLoop _ _ _ g -> g
  MorphismLoop lm    -> morphismBody lm

-- | Implicit input manipulation
data Match =
    MatchByte ByteSet       -- ^ Match a single byte
  | MatchBytes Expr         -- ^ Match a sequence of bytes
  | MatchEnd                -- ^ Match the end of input
  deriving (Generic,NFData)

data Sem = SemNo | SemYes
  deriving (Generic,NFData)

-- | Specifies the backtracking strategy for a component.
data Backtrack =
    Eager -- ^ Consume as much input as possible
  | Lazy  -- ^ Consume as much input as needed
    deriving (Generic,NFData)

data ErrorSource = ErrorFromUser | ErrorFromSystem
  deriving (Generic,NFData)

instance CoreSyn Grammar where
  coreLet       = Let
  coreCase x ps = GCase (Case x ps)
  coreCall      = Call

--------------------------------------------------------------------------------

skipAnnot :: Grammar -> Grammar
skipAnnot g =
  case g of
    Annot _ g1 -> skipAnnot g1
    _          -> g

skipGetAnnot :: Grammar -> ([Annot], Grammar)
skipGetAnnot = go []
  where
  go as g =
    case g of
      Annot a g1 -> go (a:as) g1
      _          -> (as,g)


gAnnotate :: [Annot] -> Grammar -> Grammar
gAnnotate as g = foldr Annot g as
  where
  -- can use this to only add a single src range annotation
  _addAnn a gram =
    case a of
      SrcRange {} ->
        case gram of
          Annot (SrcRange {}) _ -> gram
          Annot b g1 -> Annot b (_addAnn a g1)
          _ -> Annot a gram
      _ -> Annot a gram


-- | Apply a binary constructor but factor out common SrcRange annotations
gBinAnnotate :: (Grammar -> Grammar -> Grammar) -> Grammar -> Grammar -> Grammar
gBinAnnotate mk (Annotated as0 g1) (Annotated bs0 g2) =
  gAnnotate c (mk (gAnnotate leftAs g1) (gAnnotate rightAs g2))
  where
  (c,leftAs,rightAs) = commonSrcAnn (reverse as0) (reverse bs0)

  commonSrcAnn as bs =
    case as of
      [] -> ([], as, bs)
      a : as' ->
        case a of
          SrcRange r1 ->
            case bs of
              [] -> ([], as, bs)
              b : bs' ->
                case b of
                  SrcRange r2 -> if r1 == r2
                                    then let (cs,xs,ys) = commonSrcAnn as' bs'
                                         in (a:cs,xs,ys)
                                    else ([], as, bs)
                  _ -> let (cs,xs,ys) = commonSrcAnn as bs'
                       in (cs,xs,b:ys)
          _ -> let (cs,xs,ys) = commonSrcAnn as' bs
               in (cs, a:xs, ys)




{-# COMPLETE SkipAnnot #-}
pattern SkipAnnot :: Grammar -> Grammar
pattern SkipAnnot g <- (skipAnnot -> g)

{-# COMPLETE Annotated #-}
pattern Annotated :: [Annot] -> Grammar -> Grammar
pattern Annotated as g <- (skipGetAnnot -> (as,g))

pattern Choice :: Bool -> [Grammar] -> Grammar
pattern Choice biased cs <- (collectChoices -> Just (biased, cs))

collectChoices :: Grammar -> Maybe (Bool, [Grammar])
collectChoices g@(skipAnnot -> OrUnbiased {}) = Just (False, go g)
  where
    go (skipAnnot -> OrUnbiased l r) = go l ++ go r
    go g'               = [g']

collectChoices g@(skipAnnot -> OrBiased {}) = Just (True, go g)
  where
    go (skipAnnot -> OrBiased l r) = go l ++ go r
    go g'             = [g']

collectChoices _ = Nothing

--------------------------------------------------------------------------------

-- geb is 'grammar expr byteset'
gebChildrenG ::
  Applicative f => (Grammar -> f Grammar) -> (Expr -> f Expr) -> (ByteSet -> f ByteSet) ->
                   Grammar -> f Grammar
gebChildrenG gf ef bf gram =
  case gram of
    Pure e            -> Pure <$> ef e
    GetStream         -> pure gram
    SetStream e       -> SetStream <$> ef e
    Match s m         -> Match s <$> case m of
      MatchByte bs -> MatchByte  <$> bf bs
      MatchBytes e -> MatchBytes <$> ef e
      MatchEnd     -> pure MatchEnd
    Fail es ty m_e    -> Fail es ty <$> traverse ef m_e
    Do_ g1 g2         -> Do_ <$> gf g1 <*> gf g2
    Do  x g1 g2       -> Do x <$> gf g1 <*> gf g2
    Let x e g         -> Let x <$> ef e <*> gf g
    OrBiased g1 g2    -> OrBiased <$> gf g1 <*> gf g2
    OrUnbiased g1 g2  -> OrUnbiased <$> gf g1 <*> gf g2
    Call fn args      -> Call fn <$> traverse ef args
    Annot a g         -> Annot a <$> gf g
    GCase cs          -> GCase <$> traverse gf cs
    Loop lc           -> Loop <$> case lc of
      ManyLoop s b l m_h g -> ManyLoop s b <$> ef l <*> traverse ef m_h <*> gf g
      RepeatLoop b n e g   -> RepeatLoop b n <$> ef e <*> gf g
      MorphismLoop lm      -> MorphismLoop <$> morphismE ef gf lm

gebMapChildrenG :: (Grammar -> Grammar) -> (Expr -> Expr) -> (ByteSet -> ByteSet) ->
                   Grammar -> Grammar
gebMapChildrenG gf ef bf g = g1
  where Identity g1 = gebChildrenG (Identity . gf) (Identity . ef) (Identity . bf) g

childrenG ::
  Applicative f => (Grammar -> f Grammar) -> Grammar -> f Grammar
childrenG f = gebChildrenG f (pure . id) (pure . id)

mapChildrenG :: (Grammar -> Grammar) -> Grammar -> Grammar
mapChildrenG f g = g1
  where Identity g1 = childrenG (Identity . f) g

foldMapChildrenG :: Monoid m => (Grammar -> m) -> (Expr -> m) -> (ByteSet -> m) ->
                    Grammar -> m
foldMapChildrenG gf ef bf g = m
  where Const m = gebChildrenG (Const . gf) (Const . ef) (Const . bf) g

collectChildren :: Monoid a => (Grammar -> a) -> Grammar -> a
collectChildren f = fst . childrenG (\g -> (f g, g))


--------------------------------------------------------------------------------


instance PP ErrorSource where
  pp err =
    case err of
      ErrorFromUser   -> ".user_error"
      ErrorFromSystem -> ".system_error"

instance PP Grammar where
  pp gram =
    case gram of
      Pure e         -> "pure" <+> ppPrec 1 e
      Match s m      -> ppMatch s m
      GetStream      -> "getStream"
      SetStream e    -> "setStream" <+> ppPrec 1 e
      Fail src t e   -> ppTApp 0 ("fail" <.> suff) [t] <+> ppMb e
        where suff = case src of
                       ErrorFromUser    -> "_user"
                       ErrorFromSystem  -> "_sys"
              ppMb = maybe empty pp
      Do_ {}         -> "do" <+> ppStmts gram
      Do  {}         -> "do" <+> ppStmts gram
      Let {}         -> "do" <+> ppStmts gram
      OrBiased g1 g2 -> "try" $$ nest 2 (pp g1) $$ ppOrBiased False g2
      OrUnbiased {}  -> nest 2 (ppOrUnbiased False gram)
      Call f es      -> pp f <.> parens (commaSep (map pp es))
      Annot l g      -> "--" <+> pp l $$ pp g
      GCase c        -> pp c
      Loop lc        -> pp lc

instance (PP e, PP b) => PP (LoopClass' e b) where
  pp lc =
    case lc of
      ManyLoop s b l m_h g ->
        "Many" <.> ppBiased b <.> ppSemSuff s <+>
        parens (pp l <.> ".." <.> maybe "" pp m_h) <+> pp g
      RepeatLoop b n e g   ->
        "for" <.> ppBiased b <+> parens (pp n <+> "=" <+> pp e) <+> pp g
      MorphismLoop lm  -> pp lm    
    where
      ppBiased b = case b of
                     Eager -> ""
                     Lazy  -> "?"

ppMatch :: Sem -> Match -> Doc
ppMatch s mat =
  case mat of
    MatchBytes e -> "match" <.> ppSemSuff s <+> pp e
    MatchByte bs -> "match1" <.> ppSemSuff s <+> pp bs
    MatchEnd     -> "matchEnd"

ppSemSuff :: Sem -> Doc
ppSemSuff sem =
  case sem of
    SemYes -> ""
    SemNo  -> "_"

ppOrUnbiased :: Bool -> Grammar -> Doc
ppOrUnbiased forked gram =
  case gram of
    OrUnbiased g1 g2 -> "fork" $$ nest 2 (pp g1) $$ ppOrUnbiased False g2
    Annot a g
      | forked    -> next
      | otherwise -> "fork" $$ nest 2 next
        where next = "--" <+> pp a $$ ppOrUnbiased True g

    _
      | forked    -> next
      | otherwise -> "fork" $$ nest 2 next
      where next = pp gram

ppOrBiased :: Bool -> Grammar -> Doc
ppOrBiased forked gram =
  case gram of
    OrBiased g1 g2 -> "else try" $$ nest 2 (pp g1) $$ ppOrBiased False g2

    Annot a g
      | forked    -> next
      | otherwise -> "orelse" $$ nest 2 next
      where next = "--" <+> pp a $$ ppOrBiased True g

    _ | forked    -> next
      | otherwise -> "orelse" $$ nest 2 next
      where next = pp gram

ppStmts :: Grammar -> Doc
ppStmts gram =
  case gram of
    Do_ g1 g2  -> pp g1 $$ ppStmts g2
    Do x g1 g2 -> pp x <+> "<-" <+> pp g1 $$ ppStmts g2
    Let x e g  -> "let" <+> pp x <+> "=" <+> pp e $$ ppStmts g
    Annot a g  -> "--" <+> pp a $$ ppStmts g
    _          -> pp gram


