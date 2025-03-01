module Main where

import Control.Applicative
import Control.Arrow ((>>>))
import Control.Monad
import Control.Monad.Fail (MonadFail)
import Control.Monad.IO.Class
import Data.Generics (mkT, everywhere, listify, extT, everything, mkQ)
import Data.Function
import Data.List
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import System.Console.GetOpt
import System.Environment
import System.FilePath
import System.Directory

import qualified Language.Haskell.Exts.SrcLoc     as Hs
import qualified Language.Haskell.Exts.Syntax     as Hs
import qualified Language.Haskell.Exts.Build      as Hs
import qualified Language.Haskell.Exts.Pretty     as Hs
import qualified Language.Haskell.Exts.Parser     as Hs
import qualified Language.Haskell.Exts.ExactPrint as Hs
import qualified Language.Haskell.Exts.Extension  as Hs
import qualified Language.Haskell.Exts.Comments   as Hs

import Agda.Main (runAgda)
import Agda.Compiler.Backend
import Agda.Compiler.Common
import Agda.Interaction.BasicOps
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty hiding (pretty)
import Agda.Syntax.Common hiding (Ranged)
import qualified Agda.Syntax.Concrete.Name as C
import Agda.Syntax.Literal
import Agda.Syntax.Internal
import Agda.Syntax.Position
import Agda.Syntax.Translation.ConcreteToAbstract
import Agda.Syntax.Translation.AbstractToConcrete
import Agda.Syntax.Scope.Base
import Agda.Syntax.Scope.Monad
import Agda.TheTypeChecker
import Agda.TypeChecking.Free
import Agda.TypeChecking.Rules.Term (isType_)
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Records
import Agda.TypeChecking.Sort
import Agda.Utils.Lens
import Agda.Utils.Pretty (prettyShow)
import qualified Agda.Utils.Pretty as P
import Agda.Utils.FileName
import Agda.Utils.List
import Agda.Utils.Impossible
import Agda.Utils.Maybe.Strict (toLazy, toStrict)
import Agda.Utils.Monad
import Agda.Utils.Size

import HsUtils


data Options = Options { optOutDir     :: FilePath,
                         optExtensions :: [Hs.Extension] }

defaultOptions :: Options
defaultOptions = Options{ optOutDir = ".", optExtensions = [] }

outdirOpt :: Monad m => FilePath -> Options -> m Options
outdirOpt dir opts = return opts{ optOutDir = dir }

extensionOpt :: Monad m => String -> Options -> m Options
extensionOpt ext opts = return opts{ optExtensions = Hs.parseExtension ext : optExtensions opts }

pragmaName :: String
pragmaName = "AGDA2HS"

type Ranged a    = (Range, a)
type ModuleEnv   = ()
type ModuleRes   = ()
type CompiledDef = [Ranged [Hs.Decl ()]]

backend :: Backend' Options Options ModuleEnv ModuleRes CompiledDef
backend = Backend'
  { backendName           = "agda2hs"
  , backendVersion        = Just "0.1"
  , options               = defaultOptions
  , commandLineFlags      = [ Option ['o'] ["out-dir"] (ReqArg outdirOpt "DIR")
                              "Write Haskell code to DIR. Default: ."
                            , Option ['X'] [] (ReqArg extensionOpt "EXTENSION")
                              "Enable Haskell language EXTENSION. Affects parsing of Haskell code in FOREIGN blocks."
                            ]
  , isEnabled             = \ _ -> True
  , preCompile            = return
  , postCompile           = \ _ _ _ -> return ()
  , preModule             = moduleSetup
  , postModule            = writeModule
  , compileDef            = compile
  , scopeCheckingSuffices = False
  , mayEraseType          = \ _ -> return True
  }

-- Helpers ---------------------------------------------------------------

showTCM :: PrettyTCM a => a -> TCM String
showTCM x = show <$> prettyTCM x

hsQName :: QName -> TCM (Hs.QName ())
hsQName f
  | Just x <- isSpecialName f = return x
  | otherwise = do
    isRecordConstructor f >>= \ case
      Just (r, Record{ recNamedCon = False }) -> mkname r -- Use the record name if no named constructor
      _                                       -> mkname f
  where
    mkname x = do
      s <- showTCM x
      return $
        case break (== '.') $ reverse s of
          (_, "")      -> Hs.UnQual () (hsName s)
          (fr, _ : mr) -> Hs.Qual () (Hs.ModuleName () $ reverse mr) (hsName $ reverse fr)

freshString :: String -> TCM String
freshString s = freshName_ s >>= showTCM

(~~) :: QName -> String -> Bool
q ~~ s = show q == s

makeList :: TCM Doc -> Term -> TCM [Term]
makeList = makeList' "Agda.Builtin.List.List.[]" "Agda.Builtin.List.List._∷_"

makeList' :: String -> String -> TCM Doc -> Term -> TCM [Term]
makeList' nil cons err v = do
  v <- reduce v
  case v of
    Con c _ es
      | []      <- vis es, conName c ~~ nil  -> return []
      | [x, xs] <- vis es, conName c ~~ cons -> (x :) <$> makeList' nil cons err xs
    _ -> genericDocError =<< err
  where
    vis es = [ unArg a | Apply a <- es, visible a ]

makeListP' :: String -> String -> TCM Doc -> DeBruijnPattern -> TCM [DeBruijnPattern]
makeListP' nil cons err p = do
  case p of
    ConP c _ ps
      | []      <- vis ps, conName c ~~ nil  -> return []
      | [x, xs] <- vis ps, conName c ~~ cons -> (x :) <$> makeListP' nil cons err xs
    _ -> genericDocError =<< err
  where
    vis ps = [ namedArg p | p <- ps, visible p ]

underAbstr :: Subst t a => Dom Type -> Abs a -> (a -> TCM b) -> TCM b
underAbstr a b ret
  | absName b == "_" = underAbstraction' KeepNames a b ret
  | otherwise        = underAbstraction' KeepNames a b $ \ body ->
                         localScope $ bindVar 0 >> ret body

underAbstr_ :: Subst t a => Abs a -> (a -> TCM b) -> TCM b
underAbstr_ = underAbstr __DUMMY_DOM__

applyNoBodies :: Definition -> [Arg Term] -> Definition
applyNoBodies d args = revert $ d `apply` args
  where
    bodies :: [Maybe Term]
    bodies = map clauseBody $ funClauses $ theDef d

    setBody cl b = cl { clauseBody = b }

    revert :: Definition -> Definition
    revert d@(Defn {theDef = f@(Function {funClauses = cls})}) =
      d {theDef = f {funClauses = zipWith setBody cls bodies}}
    revert _ = __IMPOSSIBLE__

-- Builtins ---------------------------------------------------------------

isSpecialTerm :: QName -> Maybe (QName -> Elims -> TCM (Hs.Exp ()))
isSpecialTerm q = case show q of
  _ | isExtendedLambdaName q                    -> Just lambdaCase
  "Haskell.Prim.if_then_else_"                  -> Just ifThenElse
  "Haskell.Prim.Enum.Enum.enumFrom"             -> Just mkEnumFrom
  "Haskell.Prim.Enum.Enum.enumFromTo"           -> Just mkEnumFromTo
  "Haskell.Prim.Enum.Enum.enumFromThen"         -> Just mkEnumFromThen
  "Haskell.Prim.Enum.Enum.enumFromThenTo"       -> Just mkEnumFromThenTo
  "Haskell.Prim.case_of_"                       -> Just caseOf
  "Agda.Builtin.FromNat.Number.fromNat"         -> Just fromNat
  "Agda.Builtin.FromNeg.Negative.fromNeg"       -> Just fromNeg
  "Agda.Builtin.FromString.IsString.fromString" -> Just fromString
  _                                             -> Nothing

isSpecialCon :: QName -> Maybe (ConHead -> ConInfo -> Elims -> TCM (Hs.Exp ()))
isSpecialCon = show >>> \ case
  "Haskell.Prim.Tuple.Tuple._∷_" -> Just tupleTerm
  _ -> Nothing

isSpecialPat :: QName -> Maybe (ConHead -> ConPatternInfo -> [NamedArg DeBruijnPattern] -> TCM (Hs.Pat ()))
isSpecialPat = show >>> \ case
  "Haskell.Prim.Tuple.Tuple._∷_" -> Just tuplePat
  _ -> Nothing

isSpecialType :: QName -> Maybe (QName -> Elims -> TCM (Hs.Type ()))
isSpecialType = show >>> \ case
  "Haskell.Prim.Tuple.Tuple" -> Just tupleType
  "Haskell.Prim.Tuple._×_"   -> Just tupleType'
  "Haskell.Prim.Tuple._×_×_" -> Just tupleType'
  _ -> Nothing

isSpecialName :: QName -> Maybe (Hs.QName ())
isSpecialName = show >>> \ case
    "Agda.Builtin.Nat.Nat"         -> unqual "Natural"
    "Agda.Builtin.Int.Int"         -> unqual "Integer"
    "Agda.Builtin.Word.Word64"     -> unqual "Word"
    "Agda.Builtin.Float.Float"     -> unqual "Double"
    "Agda.Builtin.Bool.Bool.false" -> unqual "False"
    "Agda.Builtin.Bool.Bool.true"  -> unqual "True"
    "Agda.Builtin.List.List"       -> special Hs.ListCon
    "Agda.Builtin.List.List._∷_"   -> special Hs.Cons
    "Agda.Builtin.List.List.[]"    -> special Hs.ListCon
    "Agda.Builtin.Unit.⊤"          -> special Hs.UnitCon
    "Agda.Builtin.Unit.tt"         -> special Hs.UnitCon
    "Haskell.Prim.Tuple.Tuple.[]"  -> special Hs.UnitCon
    "Haskell.Prim._∘_"             -> unqual "_._"
    _ -> Nothing
  where
    unqual n  = Just $ Hs.UnQual () $ hsName n
    special c = Just $ Hs.Special () $ c ()

ifThenElse :: QName -> Elims -> TCM (Hs.Exp ())
ifThenElse _ es = compileArgs es >>= \case
  -- fully applied
  b : t : f : es' -> return $ Hs.If () b t f `eApp` es'
  -- partially applied -> eta-expand
  es' -> do
    xs <- fmap Hs.name . drop (length es') <$> mapM freshString ["b", "t", "f"]
    let [b, t, f] = es' ++ map Hs.var xs
    return $ Hs.lamE (Hs.pvar <$> xs) $ Hs.If () b t f

mkEnumFrom :: QName -> Elims -> TCM (Hs.Exp ())
mkEnumFrom q es = compileArgs es >>= \case
  _ : a : es' -> return $ Hs.EnumFrom () a `eApp` es'
  es'         -> return $ hsVar "enumFrom" `eApp` drop 1 es'

mkEnumFromTo :: QName -> Elims -> TCM (Hs.Exp ())
mkEnumFromTo q es = compileArgs es >>= \case
  _ : a : b : es' -> return $ Hs.EnumFromTo () a b `eApp` es'
  es'             -> return $ hsVar "enumFromTo" `eApp` drop 1 es'

mkEnumFromThen :: QName -> Elims -> TCM (Hs.Exp ())
mkEnumFromThen q es = compileArgs es >>= \case
  _ : a : a' : es' -> return $ Hs.EnumFromThen () a a' `eApp` es'
  es'              -> return $ hsVar "enumFromThen" `eApp` drop 1 es'

mkEnumFromThenTo :: QName -> Elims -> TCM (Hs.Exp ())
mkEnumFromThenTo q es = compileArgs es >>= \case
  _ : a : a' : b : es' -> return $ Hs.EnumFromThenTo () a a' b `eApp` es'
  es'                  -> return $ hsVar "enumFromThenTo" `eApp` drop 1 es'

caseOf :: QName -> Elims -> TCM (Hs.Exp ())
caseOf _ es = compileArgs es >>= \ case
  -- applied to pattern lambda
  e : Hs.LCase _ alts : es' ->
    return $ eApp (Hs.Case () e alts) es'
  -- applied to regular lambda
  e : Hs.Lambda _ (p : ps) b : es' -> do
    let lam [] = id
        lam qs = Hs.Lambda () qs
    return $ eApp (Hs.Case () e [Hs.Alt () p (Hs.UnGuardedRhs () $ lam ps b) Nothing]) es'
  -- no lambda, but fully applied: inline
  e : f : es' -> return $ eApp f $ e : es'
  -- partial application
  [e]         -> do
    let Just dollar = getOp (hsVar "_$_")
    return $ Hs.RightSection () dollar e
  -- unapplied
  []          -> return $ eApp (hsVar "flip") [hsVar "_$_"]

lambdaCase :: QName -> Elims -> TCM (Hs.Exp ())
lambdaCase q es = setCurrentRange (nameBindingSite $ qnameName q) $ do
  def@Function{ funExtLam = Just (ExtLamInfo mname _) } <- theDef <$> getConstInfo q
  npars <- size <$> lookupSection mname
  let (pars, rest) = splitAt npars es
      cs           = applyE (funClauses def) pars
  cs   <- mapM (compileClause [] $ hsName "(lambdaCase)") cs
  alts <- mapM clauseToAlt $ map snd cs -- Pattern lambdas cannot have where blocks
  args <- compileArgs rest
  return $ eApp (Hs.LCase () alts) args

clauseToAlt :: Hs.Match () -> TCM (Hs.Alt ())
clauseToAlt (Hs.Match _ _ [p] rhs wh) = pure $ Hs.Alt () p rhs wh
clauseToAlt (Hs.Match _ _ ps _ _)     = genericError $ "Pattern matching lambdas must take a single argument"
clauseToAlt Hs.InfixMatch{}           = __IMPOSSIBLE__

fromNat :: QName -> Elims -> TCM (Hs.Exp ())
fromNat _ es = compileArgs es <&> \ case
  _ : n@Hs.Lit{} : es' -> n `eApp` es'
  es'                  -> hsVar "fromIntegral" `eApp` drop 1 es'

fromNeg :: QName -> Elims -> TCM (Hs.Exp ())
fromNeg _ es = compileArgs es <&> \ case
  _ : n@Hs.Lit{} : es' -> Hs.NegApp () n `eApp` es'
  es'                  -> (hsVar "negate" `o` hsVar "fromIntegral") `eApp` drop 1 es'
  where
    f `o` g = Hs.InfixApp () f (Hs.QVarOp () $ Hs.UnQual () $ hsName "_._") g

fromString :: QName -> Elims -> TCM (Hs.Exp ())
fromString _ es = compileArgs es <&> \ case
  _ : s@Hs.Lit{} : es' -> s `eApp` es'
  es'                  -> hsVar "fromString" `eApp` drop 1 es'

tupleType' :: QName -> Elims -> TCM (Hs.Type ())
tupleType' q es = do
  Def tup es' <- reduce (Def q es)
  tupleType tup es'

tupleType :: QName -> Elims -> TCM (Hs.Type ())
tupleType _ es | Just [as] <- allApplyElims es = do
  let err = sep [ text "Argument"
                , nest 2 $ prettyTCM as
                , text "to Tuple is not a concrete list" ]
  xs <- makeList err (unArg as)
  ts <- mapM compileType xs
  return $ Hs.TyTuple () Hs.Boxed ts
tupleType _ es =
  genericDocError =<< text "Bad tuple arguments: " <?> prettyTCM es

tupleTerm :: ConHead -> ConInfo -> Elims -> TCM (Hs.Exp ())
tupleTerm cons i es = do
  let v   = Con cons i es
      err = sep [ text "Tuple value"
                , nest 2 $ prettyTCM v
                , text "does not have a known size." ]
  xs <- makeList' "Haskell.Prim.Tuple.Tuple.[]" "Haskell.Prim.Tuple.Tuple._∷_" err v
  ts <- mapM compileTerm xs
  return $ Hs.Tuple () Hs.Boxed ts

tuplePat :: ConHead -> ConPatternInfo -> [NamedArg DeBruijnPattern] -> TCM (Hs.Pat ())
tuplePat cons i ps = do
  let p = ConP cons i ps
      err = sep [ text "Tuple pattern"
                , nest 2 $ prettyTCM p
                , text "does not have a known size." ]
  xs <- makeListP' "Haskell.Prim.Tuple.Tuple.[]" "Haskell.Prim.Tuple.Tuple._∷_" err p
  qs <- mapM compilePat xs
  return $ Hs.PTuple () Hs.Boxed qs

-- Compiling things -------------------------------------------------------

data RecordTarget = ToRecord | ToClass

data ParsedPragma
  = NoPragma
  | DefaultPragma
  | ClassPragma
  | ExistingClassPragma
  | DerivingPragma [Hs.Deriving ()]

-- "class" is not being used usefully, any record with a pragma is
-- considered a typeclass

-- no pragma at all means no code is compiled
-- if the pragma contains extraneous stuff we treat it as default
-- using a class pragma currently leads to no code being compiled
processPragma :: QName -> TCM ParsedPragma
processPragma qn = getUniqueCompilerPragma pragmaName qn >>= \case
  Nothing -> return NoPragma
  Just (CompilerPragma _ s) | s == "class"          -> return ClassPragma
                            | s == "existing-class" -> return ExistingClassPragma
  Just (CompilerPragma _ s) | "deriving" `isPrefixOf` s ->
    -- parse a deriving clause for a datatype by tacking it onto a
    -- dummy datatype and then only keeping the deriving part
    case Hs.parseDecl ("data X = X " ++ s) of
      Hs.ParseFailed loc msg ->
        setCurrentRange (srcLocToRange loc) $ genericError msg
      Hs.ParseOk (Hs.DataDecl _ _ _ _ _ ds) ->
        return $ DerivingPragma (map (() <$) ds)
      Hs.ParseOk _ -> return DefaultPragma
  _ -> return DefaultPragma


compile :: Options -> ModuleEnv -> IsMain -> Definition -> TCM CompiledDef
compile _ _ _ def = processPragma (defName def) >>= \ p ->
  case (p , defInstance def , theDef def) of
    (NoPragma           , _      , _         ) -> return []
    (ExistingClassPragma, _      , _         ) -> return [] -- No code generation, but affects how projections are compiled
    (ClassPragma        , _      , Record{}  ) -> tag <$> compileRecord ToClass def
    (DerivingPragma ds  , _      , Datatype{}) -> tag <$> compileData ds def
    (DefaultPragma      , _      , Datatype{}) -> tag <$> compileData [] def
    (DefaultPragma      , Just _ , _         ) -> tag <$> compileInstance def
    (DefaultPragma      , _      , Axiom     ) -> tag <$> compilePostulate def
    (DefaultPragma      , _      , Function{}) -> tag <$> compileFun def
    (DefaultPragma      , _      , Record{}  ) -> tag <$> compileRecord ToRecord def
    _                                         -> return []
  where tag code = [(nameBindingSite $ qnameName $ defName def, code)]

compileInstance :: Definition -> TCM [Hs.Decl ()]
compileInstance def = setCurrentRange (nameBindingSite $ qnameName $ defName def) $ do
  ir <- compileInstRule [] (unEl . defType $ def)
  locals <- takeWhile (isAnonymousModuleName . qnameModule . fst)
          . dropWhile ((<= defName def) . fst)
          . sortDefs <$> curDefs
  ds <- catMaybes <$> mapM (compileInstanceClause locals) funClauses
  return $ [Hs.InstDecl () Nothing ir (Just ds)]
  where Function{..} = theDef def

compileInstRule :: [Hs.Asst ()] -> Term -> TCM (Hs.InstRule ())
compileInstRule cs ty = case unSpine  $ ty of
  Def f es | Just args <- allApplyElims es -> do
    vs <- mapM (compileType . unArg) $ filter visible args
    f <- hsQName f
    return $
      Hs.IRule () Nothing (ctx cs) $ foldl (Hs.IHApp ()) (Hs.IHCon () f) (map pars vs)
    where ctx [] = Nothing
          ctx cs = Just (Hs.CxTuple () cs)
          -- put parens around anything except a var or a constant
          pars :: Hs.Type () -> Hs.Type ()
          pars t@(Hs.TyVar () _) = t
          pars t@(Hs.TyCon () _) = t
          pars t = Hs.TyParen () t
  Pi a b
      | hidden a -> dropPi -- Hidden Pi means Haskell forall, which we leave implicit
      | isInstance a -> ifM (dependsOnVisibleVar a) dropPi $ do
          hsA <- compileType (unEl $ unDom a)
          hsB <- underAbstraction a b (compileInstRule (cs ++ [Hs.TypeA () hsA]) . unEl)
          return hsB
    where dropPi = underAbstr a b (compileInstRule cs . unEl)
  _ -> __IMPOSSIBLE__

compileInstanceClause :: LocalDecls -> Clause -> TCM (Maybe (Hs.InstDecl ()))
compileInstanceClause ls c = do
  -- abuse compileClause:
  -- 1. drop any patterns before record projection to suppress the instance arg
  -- 2. use record proj. as function name
  -- 3. process remaing patterns as usual
  case dropWhile (isNothing . isProjP) (namedClausePats c) of
    []     -> genericDocError =<< fsep (pwords $ "Type class instances must be defined using copatterns and " ++
                                                 "cannot be defined using helper functions or record expressions.")
    p : ps -> do
      let c' = c {namedClausePats = ps}
          ProjP _ q = namedArg p

      -- We want the actual field name, not the instance-opened projection.
      (q, _, _) <- origProjection q

      let uf = hsName (show (nameConcrete (qnameName q)))
      (_ , x) <- compileClause ls uf c'
      arg <- fieldArgInfo q
      if visible arg
        then return $ Just $ Hs.InsDecl () (Hs.FunBind () [x])
        else return Nothing

fieldArgInfo :: QName -> TCM ArgInfo
fieldArgInfo f = do
  r <- maybe badness return =<< getRecordOfField f
  Record{ recFields = fs } <- theDef <$> getConstInfo r
  case filter ((== f) . unDom) fs of
    df : _ -> return $ getArgInfo df
    []     -> badness
  where
    badness = genericDocError =<< text "Not a record field:" <+> prettyTCM f


compileRecord :: RecordTarget -> Definition -> TCM [Hs.Decl ()]
compileRecord target def = setCurrentRange (nameBindingSite $ qnameName $ defName def) $ do
  TelV tel _ <- telViewUpTo recPars (defType def)
  hd <- addContext tel $ do
    let params = teleArgs tel :: [Arg Term]
    pars <- mapM (showTCM . unArg) $ filter visible params
    return $ foldl (\ h p -> Hs.DHApp () h (Hs.UnkindedVar () $ hsName p))
                   (Hs.DHead () (hsName rName))
                   pars
  case target of
    ToClass -> do
      classDecls <- compileRecFields classDecl recPars (unDom <$> recFields) recTel
      return [Hs.ClassDecl () Nothing hd [] (Just classDecls)]

    ToRecord -> do
      fieldDecls <- compileRecFields fieldDecl recPars (unDom <$> recFields) recTel
      mapM_ checkFieldInScope (map unDom recFields)
      let conDecl = Hs.QualConDecl () Nothing Nothing $ Hs.RecDecl () cName fieldDecls
      return [Hs.DataDecl () (Hs.DataType ()) Nothing hd [conDecl] []]

  where
    rName = prettyShow $ qnameName $ defName def
    cName | recNamedCon = hsName $ prettyShow $ qnameName $ conName recConHead
          | otherwise   = hsName rName   -- Reuse record name for constructor if no given name

    -- In Haskell, projections live in the same scope as the record type, so check here that the
    -- record module has been opened.
    checkFieldInScope f = hsQName f >>= \ case
      Hs.UnQual{}  -> return ()
      Hs.Special{} -> __IMPOSSIBLE__
      Hs.Qual{}    -> setCurrentRange (nameBindingSite $ qnameName f) $ genericError $
        "Record projections (`" ++ prettyShow (qnameName f) ++ "` in this case) must be brought into scope when compiling to Haskell record types. " ++
        "Add `open " ++ rName ++ " public` after the record declaration to fix this."

    Record{..} = theDef def

    classDecl :: Hs.Name () -> Hs.Type () -> Hs.ClassDecl ()
    classDecl n = Hs.ClsDecl () . Hs.TypeSig () [n]

    fieldDecl :: Hs.Name () -> Hs.Type () -> Hs.FieldDecl ()
    fieldDecl n = Hs.FieldDecl () [n]

    compileRecFields :: (Hs.Name () -> Hs.Type () -> b)
                     -> Int -> [QName] -> Telescope -> TCM [b]
    compileRecFields decl i ns tel =
      case (ns, splitTelescopeAt i tel) of
        (_     ,(_   ,EmptyTel      )) -> return []
        (n:ns,(tel',ExtendTel ty _)) -> do
          ty  <- addContext tel' $
                   compileType (unEl $ unDom ty)
                   <&> decl (hsName $ prettyShow $ qnameName n)
          tys <- compileRecFields decl (i+1) ns tel
          return (ty:tys)
        (_, _) -> __IMPOSSIBLE__


compileData :: [Hs.Deriving ()] -> Definition -> TCM [Hs.Decl ()]
compileData ds def = do
  let d = hsName $ prettyShow $ qnameName $ defName def
  case theDef def of
    Datatype{dataPars = n, dataIxs = numIxs, dataCons = cs} -> do
      unless (numIxs == 0) $ genericDocError =<< text "Not supported: indexed datatypes"
      TelV tel _ <- telViewUpTo n (defType def)
      addContext tel $ do
        let params = teleArgs tel :: [Arg Term]
        pars <- mapM (showTCM . unArg) $ filter visible params
        cs   <- mapM (compileConstructor params) cs
        let hd   = foldl (\ h p -> Hs.DHApp () h (Hs.UnkindedVar () $ hsName p))
                         (Hs.DHead () d) pars
        return [Hs.DataDecl () (Hs.DataType ()) Nothing hd cs ds]
    _ -> __IMPOSSIBLE__

compileConstructor :: [Arg Term] -> QName -> TCM (Hs.QualConDecl ())
compileConstructor params c = do
  ty <- (`piApplyM` params) . defType =<< getConstInfo c
  TelV tel _ <- telView ty
  c <- showTCM c
  args <- compileConstructorArgs tel
  return $ Hs.QualConDecl () Nothing Nothing $ Hs.ConDecl () (hsName c) args

compileConstructorArgs :: Telescope -> TCM [Hs.Type ()]
compileConstructorArgs EmptyTel = return []
compileConstructorArgs (ExtendTel a tel) = compileDom a >>= \case
  DomType hsA       -> (hsA :) <$> underAbstraction a tel compileConstructorArgs
  DomConstraint hsA -> genericDocError =<< text "Not supported: constructors with class constraints"
  DomDropped        -> underAbstraction a tel compileConstructorArgs

compilePostulate :: Definition -> TCM [Hs.Decl ()]
compilePostulate def = do
  let n = qnameName (defName def)
      x = hsName $ prettyShow n
  setCurrentRange (nameBindingSite n) $ do
    ty <- compileType (unEl $ defType def)
    let body = hsError $ "postulate: " ++ pp ty
    return [ Hs.TypeSig () [x] ty
           , Hs.FunBind () [Hs.Match () x [] (Hs.UnGuardedRhs () body) Nothing] ]

type LocalDecls = [(QName, Definition)]

compileFun :: Definition -> TCM [Hs.Decl ()]
compileFun d = do
  locals <- takeWhile (isAnonymousModuleName . qnameModule . fst)
          . dropWhile ((<= defName d) . fst)
          . sortDefs <$> curDefs
  compileFun' d locals

compileFun' :: Definition -> LocalDecls -> TCM [Hs.Decl ()]
compileFun' def@(Defn {..}) locals = do
  let n = qnameName defName
      x = hsName $ prettyShow n
      go = foldM $ \(ds, ms) -> compileClause ds x >=> return . fmap (ms `snoc`)
  setCurrentRange (nameBindingSite n) $ do
    ifM (endsInSort defType) (compileTypeDef x def locals) $ do
      ty <- compileType (unEl defType)
      cs <- snd <$> go (locals, []) funClauses
      return [Hs.TypeSig () [x] ty, Hs.FunBind () cs]
  where
    Function{..} = theDef

    endsInSort t = do
      TelV tel b <- telView t
      addContext tel $ ifIsSort b (\_ -> return True) (return False)

compileTypeDef :: Hs.Name () -> Definition -> LocalDecls -> TCM [Hs.Decl ()]
compileTypeDef name (Defn {..}) locals = do
  noLocals locals
  Clause{..} <- singleClause funClauses
  addContext (KeepNames clauseTel) $ localScope $ do
    as <- compileTypeArgs namedClausePats
    let hd = foldl (Hs.DHApp ()) (Hs.DHead () name) as
    rhs <- compileType $ fromMaybe __IMPOSSIBLE__ clauseBody
    return [Hs.TypeDecl () hd rhs]

  where
    Function{..} = theDef
    noLocals locals = unless (null locals) $
      genericError "Not supported: type definition with `where` clauses"
    singleClause = \case
      [cl] -> return cl
      _    -> genericError "Not supported: type definition with several clauses"

compileTypeArgs :: NAPs -> TCM [Hs.TyVarBind ()]
compileTypeArgs ps = mapM (compileTypeArg . namedArg) $ filter visible ps

compileTypeArg :: DeBruijnPattern -> TCM (Hs.TyVarBind ())
compileTypeArg p@(VarP o _) = Hs.UnkindedVar () . hsName <$> showTCM p
compileTypeArg _ = genericError "Not supported: type definition by pattern matching"

compileClause :: LocalDecls -> Hs.Name () -> Clause -> TCM (LocalDecls, Hs.Match ())
compileClause locals x c@Clause{clauseTel = tel, namedClausePats = ps', clauseBody = body} = do
  addContext (KeepNames tel) $ localScope $ do
    scopeBindPatternVariables ps'
    ps <- compilePats ps'

    -- Compile rhs and its @where@ clauses, making sure that:
    --   * inner modules get instantiated
    --   * references to inner modules get un-qualifiyed (and instantiated)
    let localUses = nub $ listify (`elem` map fst locals) body
        belongs q@(QName m _) (QName m0 _) =
          ((show m0 ++ "._") `isPrefixOf` show m) && (q `notElem` localUses)
        splitDecls :: LocalDecls -> ([(Definition, LocalDecls)], LocalDecls)
        splitDecls ds@((q,child):rest)
          | any ((`elem` localUses) . fst) ds
          , (grandchildren, outer) <- span ((`belongs` q) . fst) rest
          , (groups, rest') <- splitDecls outer
          = ((child, grandchildren) : groups, rest')
          | otherwise = ([], ds)
        splitDecls [] = ([], [])
        (children, locals') = splitDecls locals

        args   = teleArgs tel
        argLen = length args

        -- 1. apply current telescope to inner definitions
        children' = everywhere (mkT (`applyNoBodies` args)) children

        -- 2. shrink calls to inner modules (unqualify + partially apply module parameters)
        localNames = concatMap (\(d,ds) -> defName d : map fst ds) children
        shrinkLocalDefs t | Def q es <- t, q `elem` localNames
                          = Def (qualify_ $ qnameName q) (drop argLen es)
                          | otherwise = t
        (body', children'') = everywhere (mkT shrinkLocalDefs) (body, children')

    body' <- fromMaybe (hsError $ pp x ++ ": impossible") <$> mapM compileTerm body'
    whereDecls <- concat <$> mapM (uncurry compileFun') children''

    let rhs = Hs.UnGuardedRhs () body'
        whereBinds | null whereDecls = Nothing
                   | otherwise       = Just $ Hs.BDecls () whereDecls
        match = case (x, ps) of
          (Hs.Symbol{}, p : q : ps) -> Hs.InfixMatch () p x (q : ps) rhs whereBinds
          _                         -> Hs.Match () x ps rhs whereBinds
    return (locals', match)

-- When going under a binder we need to update the scope as well as the context in order to get
-- correct printing of variable names (Issue #14).

scopeBindPatternVariables :: NAPs -> TCM ()
scopeBindPatternVariables = mapM_ (scopeBind . namedArg)
  where
    scopeBind :: DeBruijnPattern -> TCM ()
    scopeBind = \ case
      VarP o i | PatOVar x <- patOrigin o -> bindVariable LambdaBound (nameConcrete x) x
               | otherwise                -> return ()
      ConP _ _ ps -> scopeBindPatternVariables ps
      DotP{}      -> return ()
      LitP{}      -> return ()
      ProjP{}     -> return ()
      IApplyP{}   -> return ()
      DefP{}      -> return ()

bindVar :: Int -> TCM ()
bindVar i = do
  x <- nameOfBV i
  bindVariable LambdaBound (nameConcrete x) x

-- | Instance arguments that depend on visible arguments (i.e. arguments that appear in the Haskell
--   code) should not be turned into type class constraints. These are proof objects that only exist
--   on the Agda side.
dependsOnVisibleVar :: Free t => t -> TCM Bool
dependsOnVisibleVar t = do
  vis <- Set.fromList . map fst . filter (visible . snd) . zip [0..] <$> getContext
  return $ any (`Set.member` vis) $ (freeVars t :: [Int])

compileType :: Term -> TCM (Hs.Type ())
compileType t = do
  case t of
    Pi a b -> compileDom a >>= \case
      DomType hsA -> do
        hsB <- underAbstraction a b $ compileType . unEl
        return $ Hs.TyFun () hsA hsB
      DomConstraint hsA -> do
        hsB <- underAbstraction a b (compileType . unEl)
        return $ Hs.TyForall () Nothing (Just hsA) hsB
      DomDropped -> underAbstr a b (compileType . unEl)
    Def f es
      | Just semantics <- isSpecialType f -> setCurrentRange f $ semantics f es
      | Just args <- allApplyElims es -> do
        vs <- mapM (compileType . unArg) $ filter visible args
        f <- hsQName f
        return $ tApp (Hs.TyCon () f) vs
    Var x es | Just args <- allApplyElims es -> do
      vs <- mapM (compileType . unArg) $ filter visible args
      x  <- hsName <$> showTCM (Var x [])
      return $ tApp (Hs.TyVar () x) vs
    Sort s -> return (Hs.TyStar ())
    t -> genericDocError =<< text "Bad Haskell type:" <?> prettyTCM t

-- Currently we can compile an Agda "Dom Type" in three ways:
-- - To a type in Haskell
-- - To a typeclass constraint in Haskell
-- - To nothing (e.g. for proofs)
data CompiledDom
  = DomType (Hs.Type ())
  | DomConstraint (Hs.Context ())
  | DomDropped

compileDom :: Dom Type -> TCM CompiledDom
compileDom a
  | hidden a     = return DomDropped -- Hidden Pi means Haskell forall, which we leave implicit
  | visible a    = DomType <$> compileType (unEl $ unDom a)
  | isInstance a = ifM (dependsOnVisibleVar a) (return DomDropped) $
      DomConstraint . Hs.CxSingle () . Hs.TypeA () <$> compileType (unEl $ unDom a)
  | otherwise    = return DomDropped

-- Exploits the fact that the name of the record type and the name of the record module are the
-- same, including the unique name ids.
isClassFunction :: QName -> TCM Bool
isClassFunction q
  | null $ mnameToList m = return False
  | otherwise            =
    getConstInfo' (mnameToQName m) >>= \ case
      Right Defn{defName = r, theDef = Record{}} ->
        -- It would be nicer if we remembered this from when we looked at the record the first time.
        processPragma r <&> \ case
          ClassPragma         -> True
          ExistingClassPragma -> True
          _                   -> False
      _                             -> return False
  where
    m = qnameModule q

compileTerm :: Term -> TCM (Hs.Exp ())
compileTerm v =
  case unSpine v of
    Var x es   -> (`app` es) . hsVar =<< showTCM (Var x [])
    -- v currently we assume all record projections are instance
    -- args that need attention
    Def f es
      | Just semantics <- isSpecialTerm f -> semantics f es
      | otherwise -> isClassFunction f >>= \ case
        True -> do
          -- v not sure why this fails to strip the name
          --f <- hsQName builtins (qualify_ (qnameName f))
          -- here's a horrible way to strip the module prefix off the name
          let uf = show (nameConcrete (qnameName f))
          (`appStrip` es) (hsVar uf)
        False -> (`app` es) . Hs.Var () =<< hsQName f
    Con h i es
      | Just semantics <- isSpecialCon (conName h) -> semantics h i es
    Con h i es -> (`app` es) . Hs.Con () =<< hsQName (conName h)
    Lit (LitNat _ n)    -> return $ Hs.intE n
    Lit (LitFloat _ d)  -> return $ Hs.Lit () $ Hs.Frac () (toRational d) (show d)
    Lit (LitWord64 _ w) -> return $ Hs.Lit () $ Hs.PrimWord () (fromIntegral w) (show w)
    Lit (LitChar _ c)   -> return $ Hs.charE c
    Lit (LitString _ s) -> return $ Hs.Lit () $ Hs.String () s s
    Lam v b | visible v, getOrigin v == UserWritten -> do
      hsLambda (absName b) <$> underAbstr_ b compileTerm
    Lam v b | visible v ->
      -- System-inserted lambda, no need to preserve the name.
      underAbstraction_ b $ \ body -> do
        x <- showTCM (Var 0 [])
        let hsx = hsVar x
        body <- compileTerm body
        return $ case body of
          Hs.InfixApp _ a op b
            | a == hsx -> Hs.RightSection () op b -- System-inserted visible lambdas can only come from sections
          _            -> hsLambda x body         -- so we know x is not free in b.
    Lam v b ->
      -- Drop non-visible lambdas (#65)
      underAbstraction_ b $ \ body -> compileTerm body
    t -> genericDocError =<< text "bad term:" <?> prettyTCM t
  where
    app :: Hs.Exp () -> Elims -> TCM (Hs.Exp ())
    app hd es = eApp <$> pure hd <*> compileArgs es

    -- `appStrip` is used when we have a record projection and we want to
    -- drop the first visible arg (the record)
    appStrip :: Hs.Exp () -> Elims -> TCM (Hs.Exp ())
    appStrip hd es = do
      let Just args = allApplyElims es
      args <- mapM (compileTerm . unArg) $ tail $ filter visible args
      return $ eApp hd args



compilePats :: NAPs -> TCM [Hs.Pat ()]
compilePats ps = mapM (compilePat . namedArg) $ filter visible ps

compilePat :: DeBruijnPattern -> TCM (Hs.Pat ())
compilePat p@(VarP o _)
  | PatOWild <- patOrigin o = return $ Hs.PWildCard ()
  | otherwise               = Hs.PVar () . hsName <$> showTCM p
compilePat (ConP h i ps)
  | Just semantics <- isSpecialPat (conName h) = setCurrentRange h $ semantics h i ps
compilePat (ConP h _ ps) = do
  ps <- compilePats ps
  c <- hsQName (conName h)
  return $ pApp c ps
-- TODO: LitP
compilePat (ProjP _ q) = do
  let x = hsName $ prettyShow q
  return $ Hs.PVar () x
compilePat p = genericDocError =<< text "bad pattern:" <?> prettyTCM p

compileArgs :: Elims -> TCM [Hs.Exp ()]
compileArgs es = do
  let Just args = allApplyElims es
  mapM (compileTerm . unArg) $ filter visible args

-- FOREIGN pragmas --------------------------------------------------------

type Code = (Hs.Module Hs.SrcSpanInfo, [Hs.Comment])

languagePragmas :: Code -> [Hs.Extension]
languagePragmas (Hs.Module _ _ ps _ _, _) =
  [ Hs.parseExtension s | Hs.LanguagePragma _ ss <- ps, Hs.Ident _ s <- ss ]
languagePragmas _ = []

getForeignPragmas :: [Hs.Extension] -> TCM [(Range, Code)]
getForeignPragmas exts = do
  pragmas <- fromMaybe [] . Map.lookup pragmaName . iForeignCode <$> curIF
  getCode exts $ reverse pragmas
  where
    getCode :: [Hs.Extension] -> [ForeignCode] -> TCM [(Range, Code)]
    getCode _ [] = return []
    getCode exts (ForeignCode r code : pragmas) = do
          let Just file = fmap filePath $ toLazy $ rangeFile r
              pmode = Hs.defaultParseMode { Hs.parseFilename     = file,
                                            Hs.ignoreLinePragmas = False,
                                            Hs.extensions        = exts }
              line = case posLine <$> rStart r of
                       Just l  -> "{-# LINE " ++ show l ++ show file ++ " #-}\n"
                       Nothing -> ""
          case Hs.parseWithComments pmode (line ++ code) of
            Hs.ParseFailed loc msg -> setCurrentRange (srcLocToRange loc) $ genericError msg
            Hs.ParseOk m           -> ((r, m) :) <$> getCode (exts ++ languagePragmas m) pragmas

-- Rendering --------------------------------------------------------------

type Block = Ranged [String]

sortRanges :: [Ranged a] -> [a]
sortRanges = map snd . sortBy (compare `on` rLine . fst)

rLine :: Range -> Int
rLine r = fromIntegral $ fromMaybe 0 $ posLine <$> rStart r

renderBlocks :: [Block] -> String
renderBlocks = unlines . map unlines . sortRanges . filter (not . null . snd)

defBlock :: CompiledDef -> [Block]
defBlock def = [ (r, map (pp . insertParens) ds) | (r, ds) <- def ]

codePragmas :: [Ranged Code] -> [Block]
codePragmas code = [ (r, map pp ps) | (r, (Hs.Module _ _ ps _ _, _)) <- code ]

codeBlocks :: [Ranged Code] -> [Block]
codeBlocks code = [(r, [uncurry Hs.exactPrint $ moveToTop $ noPragmas mcs]) | (r, mcs) <- code, nonempty mcs]
  where noPragmas (Hs.Module l h _ is ds, cs) = (Hs.Module l h [] is ds, cs)
        noPragmas m                           = m
        nonempty (Hs.Module _ _ _ is ds, cs) = not $ null is && null ds && null cs
        nonempty _                           = True

-- Checking imports -------------------------------------------------------

imports :: [Ranged Code] -> [Hs.ImportDecl Hs.SrcSpanInfo]
imports modules = concat [imps | (_, (Hs.Module _ _ _ imps _, _)) <- modules]

autoImports :: [(String, String)]
autoImports = [("Natural", "Numeric.Natural")]

addImports :: [Hs.ImportDecl Hs.SrcSpanInfo] -> [CompiledDef] -> TCM [Hs.ImportDecl ()]
addImports is defs = do
  return [ doImport ty imp | (ty, imp) <- autoImports,
                             uses ty defs && not (any (isImport ty imp) is)]
  where
    doImport :: String -> String -> Hs.ImportDecl ()
    doImport ty imp = Hs.ImportDecl ()
      (Hs.ModuleName () imp) False False False Nothing Nothing
      (Just $ Hs.ImportSpecList () False [Hs.IVar () $ Hs.name ty])

    isImport :: String -> String -> Hs.ImportDecl Hs.SrcSpanInfo -> Bool
    isImport ty imp = \case
      Hs.ImportDecl _ (Hs.ModuleName _ m) False _ _ _ _ specs | m == imp ->
        case specs of
          Just (Hs.ImportSpecList _ hiding specs) ->
            not hiding && ty `elem` concatMap getExplicitImports specs
          Nothing -> True
      _ -> False

checkImports :: [Hs.ImportDecl Hs.SrcSpanInfo] -> TCM ()
checkImports is = do
  case concatMap checkImport is of
    []  -> return ()
    bad@((r, _, _):_) -> setCurrentRange r $
      genericDocError =<< vcat
        [ text "Bad import of builtin type"
        , nest 2 $ vcat [ text $ ty ++ " from module " ++ m ++ " (expected " ++ okm ++ ")"
                        | (_, m, ty) <- bad, let Just okm = lookup ty autoImports ]
        , text "Note: imports of builtin types are inserted automatically if omitted."
        ]

checkImport :: Hs.ImportDecl Hs.SrcSpanInfo -> [(Range, String, String)]
checkImport i
  | Just (Hs.ImportSpecList _ False specs) <- Hs.importSpecs i =
    [ (r, mname, ty) | (r, ty) <- concatMap (checkImportSpec mname) specs ]
  | otherwise = []
  where
    mname = pp (Hs.importModule i)
    checkImportSpec :: String -> Hs.ImportSpec Hs.SrcSpanInfo -> [(Range, String)]
    checkImportSpec mname = \case
      Hs.IVar       loc   n    -> check loc n
      Hs.IAbs       loc _ n    -> check loc n
      Hs.IThingAll  loc   n    -> check loc n
      Hs.IThingWith loc   n ns -> concat $ check loc n : map check' ns
      where
        check' cn = check (cloc cn) (cname cn)
        check loc n = [(srcSpanInfoToRange loc, s) | let s = pp n, badImp s]
        badImp s = maybe False (/= mname) $ lookup s autoImports

-- Generating the files -------------------------------------------------------

moduleFileName :: Options -> ModuleName -> FilePath
moduleFileName opts name =
  optOutDir opts </> C.moduleNameToFileName (toTopLevelModuleName name) "hs"

moduleSetup :: Options -> IsMain -> ModuleName -> FilePath -> TCM (Recompile ModuleEnv ModuleRes)
moduleSetup _ _ _ _ = do
  setScope . iInsideScope =<< curIF
  return $ Recompile ()

ensureDirectory :: FilePath -> IO ()
ensureDirectory = createDirectoryIfMissing True . takeDirectory

writeModule :: Options -> ModuleEnv -> IsMain -> ModuleName -> [CompiledDef] -> TCM ModuleRes
writeModule opts _ isMain m defs0 = do
  code <- getForeignPragmas (optExtensions opts)
  let defs = concatMap defBlock defs0 ++ codeBlocks code
  let imps = imports code
  unless (null code && null defs) $ do
    -- Check user-supplied imports
    checkImports imps
    -- Add automatic imports for builtin types (if any)
    let unlines' [] = []
        unlines' ss = unlines ss ++ "\n"
    autoImports <- unlines' . map pp <$> addImports imps defs0
    -- The comments makes it hard to generate and pretty print a full module
    let hsFile = moduleFileName opts m
        output = concat
                 [ renderBlocks $ codePragmas code
                 , "module " ++ prettyShow m ++ " where\n\n"
                 , autoImports
                 , renderBlocks defs ]
    reportSLn "" 1 $ "Writing " ++ hsFile
    liftIO $ ensureDirectory hsFile
    liftIO $ writeFile hsFile output

main = runAgda [Backend backend]
