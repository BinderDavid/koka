-----------------------------------------------------------------------------
-- Copyright 2016 Microsoft Corporation, Daan Leijen
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the file "license.txt" at the root of this distribution.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Transform user-defined effects into monadic bindings.
-----------------------------------------------------------------------------

module Core.Monadic( monTransform, monType ) where


import Lib.Trace 
import Control.Monad
import Control.Applicative

import Lib.PPrint
import Common.Failure
import Common.Name
import Common.Range
import Common.Unique
import Common.NamePrim( nameEffectOpen, nameYieldOp, nameReturn, nameTpCont, nameDeref, nameByref,
                        nameEnsureK, nameTrue, nameFalse, nameTpBool, nameApplyK, nameUnsafeTotal, nameIsValidK,
                        nameBind, nameLift, nameTpYld )
import Common.Error
import Common.Syntax

import Kind.Kind( kindStar, isKindEffect, kindFun, kindEffect,   kindHandled )
import Type.Type
import Type.Kind
import Type.TypeVar
import Type.Pretty hiding (Env)
import qualified Type.Pretty as Pretty
import Type.Assumption
import Type.Operations( freshTVar )
import Core.Core
import qualified Core.Core as Core
import Core.Pretty

monTransform :: Pretty.Env -> DefGroups -> Error DefGroups
monTransform penv defs
  = runMon penv 0 (monDefGroups defs)

{--------------------------------------------------------------------------
  transform definition groups
--------------------------------------------------------------------------}  
monDefGroups :: DefGroups -> Mon DefGroups
monDefGroups monDefGroups
  = do defGroupss <- mapM monDefGroup monDefGroups
       return (concat defGroupss)

monDefGroup (DefRec defs) 
  = do defss <- mapM (monDef True) defs
       return [DefRec (concat defss)]

monDefGroup (DefNonRec def)
  = do defs <- monDef False def
       return (map DefNonRec defs)


{--------------------------------------------------------------------------
  transform a definition
--------------------------------------------------------------------------}  
monDef :: Bool -> Def -> Mon [Def]
monDef recursive def 
  = do needMon <- needsMonDef def
       if (not (needMon)) -- only translate when necessary
        then return [def]
        else if (isDupFunctionDef (defExpr def))
              then do defs' <- monLetDef recursive def -- re-use letdef
                      case (defs' (\(xds,yds,nds) -> Let (DefRec xds:DefRec yds:map DefNonRec nds) (Var (defTName def) InfoNone))) of
                        Let dgs _ -> return (flattenDefGroups dgs)
                        expr -> do monTraceDoc $ \env -> text "Core.Mon.monDef: illegal duplicated definition: " <+> prettyExpr env expr
                                   failure "Core.Mon.monDef: internal failure"
              else withCurrentDef def $
                   do expr' <- monExpr' True (defExpr def)
                      return [def{ defExpr = expr' id }] -- at top level this should be ok since the type is total
                                   

type Trans a = TransX a a 
type TransX a b  = (a -> b) ->b

monExpr :: Expr -> Mon (TransX Expr Expr)
monExpr expr
  = do monExpr' False expr

monExpr' :: Bool -> Expr -> Mon (TransX Expr Expr)
monExpr' topLevel expr 
  = case expr of
      -- open
      -- simplify open away if it is directly applied
        {-
      App (App (TypeApp (Var open _) [effFrom, effTo]) [f]) args
        | getName open == nameEffectOpen 
        -> monExpr (App f args)
      -}


      --  lift _open_ applications
      
      App eopen@(TypeApp (Var open _) [effFrom,effTo]) [f]
        | getName open == nameEffectOpen         
        -> do monkFrom <- getMonType effFrom
              monkTo   <- getMonType effTo
              if (monkFrom /= NoMon || monkTo == NoMon)
               -- simplify open away if already in cps form, or not in cps at all
               then do monTraceDoc $ \env -> text "open: ignore: " <+> prettyExpr env expr <+> text ": effects" <+> tupled (niceTypes env [effFrom,effTo])
                       -- monExpr f                       
                       f' <- monExpr f
                       return $ \k -> f' (\ff -> k (App eopen [ff]))
              -- lift the function to a monadic function
               else do monTraceDoc $ \env -> text "open: lift: " <+> prettyExpr env expr
                       let Just((partps,_,restp)) = splitFunType (typeOf f)
                       pars <- mapM (\(name,partp) ->
                                     do pname <- if (name==nameNil) then uniqueName "x" else return name
                                        return (TName pname partp)) partps
                       let args = [Var tname InfoNone | tname <- pars]                       
                       -- The first argument should be 'True' if we need to ensure _k is defined;
                       -- see algeff/open1a for a good example. If the to effect is guaranteed to be 
                       -- in cps, we can leave out the check (which enables the simplifier to do a better job)
                       f' <- monExpr f
                       return $ \k -> k (Lam pars effTo (f' (\ff -> appLift (App ff args))))
      
      -- leave 'return' in place
      App ret@(Var v _) [arg] | getName v == nameReturn
        -> do -- monTraceDoc $ \env -> text "found return: " <+> prettyExpr env expr
              -- monExpr arg
              arg' <- monExpr arg
              ismon <- isMonadic
              let lift = if (ismon) then appLift else id
              return $ \k -> arg' (\xx -> k (App ret [lift xx]))  

      -- lift out lambda's into definitions so they can be duplicated if necessary                  
      TypeLam tpars (Lam pars eff body) | not topLevel 
        -> monExprAsDef tpars pars eff body
      Lam pars eff body | not topLevel
        -> monExprAsDef [] pars eff body

      -- regular cases
      Lam args eff body 
        -> do monk <- getMonEffect eff
              if (monk == NoMon)
               then withMonadic False $
                    do -- monTraceDoc $ \env -> text "not effectful lambda:" <+> niceType env eff
                       body' <- monExpr body
                       args' <- mapM monTName args                      
                       return $ \k -> k (Lam args' eff (body' id))
               else -- mon converted lambda
                    monLambda False args eff body

      App f args
        -> do f' <- monExpr f
              args' <- mapM monExpr args
              let -- ff  = f' id
                  ftp = typeOf f -- ff
                  Just(_,feff,_) = splitFunType ftp
              isMonF <- needsMonType ftp
              monTraceDoc $ \env -> text "app" <+> (if isNeverMon f then text "never-mon" else text "") <+> prettyExpr env f <+> text ",tp:" <+> niceType env (typeOf f)
              if ((not (isMonF || isAlwaysMon f)) || isNeverMon f)
               then return $ \k -> 
                f' (\ff -> 
                  applies args' (\argss -> 
                    k (App ff argss)
                ))
               else  do monTraceDoc $ \env -> text "app mon:" <+> prettyExpr env expr
                        nameY <- uniqueName "y"
                        return $ \k ->
                          let resTp = typeOf expr
                              tnameY = TName nameY resTp
                              contBody = k (Var tnameY InfoNone)
                              cont = case contBody of
                                        -- optimize (fun(y) { let x = y in .. })
                                       Let [DefNonRec def@(Def{ defExpr = Var v _ })] body 
                                        | getName v == nameY 
                                        -> Lam [TName (defName def) (defType def)] feff body 
                                       -- TODO: optimize (fun (y) { lift(expr) } )?
                                       body -> Lam [tnameY] feff body
                          in
                          f' (\ff ->
                            applies args' (\argss -> 
                              appBind resTp feff (typeOf contBody) (App ff argss) cont
                          ))
      Let defgs body 
        -> do defgs' <- monLetGroups defgs
              body'  <- monExpr body
              return $ \k -> defgs' (\dgs -> Let dgs (body' k))

      Case exprs bs
        -> do exprs' <- monTrans monExpr exprs
              bs'    <- mapM monBranch bs
              return $ \k -> exprs' (\xxs -> k (Case xxs bs'))

      Var (TName name tp) info
        -> do -- tp' <- monTypeX tp
              return (\k -> k (Var (TName name tp) info)) 

      -- type application and abstraction

      TypeApp (TypeLam tvars body) tps  | length tvars == length tps
        -- propagate types so that the pure tvs are maintained.
        -- todo: This will fail if the typeapp is not directly around the type lambda!
        -> do monExpr' topLevel (subNew (zip tvars tps) |-> body)

      TypeLam tvars body
        -> do body' <- monExpr' topLevel body
              return $ \k -> body' (\xx -> k (TypeLam tvars xx))
      
      TypeApp body tps
        -> do body' <- monExpr' topLevel body
              return $ \k -> body' (\xx -> k (TypeApp xx tps))
                   
      _ -> return (\k -> k expr) -- leave unchanged


monLambda :: Bool -> [TName] -> Effect -> Expr -> Mon (Trans Expr)
monLambda ensure pars eff body 
  = do withMonadic True $
        withMonTVars (freeEffectTVars eff) $ -- todo: is this correct?
         do body' <- monExpr body
            pars' <- mapM monTName pars 
            return $ \k -> 
              k (Lam pars' eff 
                  ((body' id)))

monExprAsDef :: [TypeVar] -> [TName] -> Effect -> Expr -> Mon (Trans Expr)
monExprAsDef tpars pars eff body
  = do let expr = addTypeLambdas tpars (Lam pars eff body)
       monk <- getMonEffect eff
       if (monk/=PolyMon)
         then monExpr' True expr 
         else do name <- uniqueName "lam"
                 let expr = addTypeLambdas tpars (Lam pars eff body)
                     tp   = typeOf expr
                     def  = Def name tp expr Private DefFun rangeNull ""
                     var  = Var (TName name tp) (InfoArity (length tpars) (length pars))
                 -- monTraceDoc $ \env -> text "mon as expr:" <--> prettyExpr env expr
                 monExpr (Let [DefNonRec def] var) -- process as let definition

monBranch :: Branch -> Mon Branch
monBranch (Branch pat guards)
  = do guards' <- mapM monGuard guards
       return $ Branch pat guards'

monGuard :: Guard -> Mon Guard
monGuard (Guard guard body)       
  = do -- guard' <- monExpr guard  -- guards are total!
       body'  <- monExpr body
       return $ Guard guard (body' id)

monLetGroups :: DefGroups -> Mon (TransX DefGroups Expr)
monLetGroups dgs 
  = do dgss' <- monTrans monLetGroup dgs
       return $ \k -> dgss' (\dgss -> k (concat dgss))
  -- = monDefGroups dgs
  
monLetGroup :: DefGroup -> Mon (TransX [DefGroup] Expr)
monLetGroup dg
  = case dg of
      DefRec defs -> do ldefs <- monTrans (monLetDef True) defs
                        return $ \k -> ldefs (\xss -> k (concat [DefRec xds : DefRec yds : map DefNonRec nds | (xds,yds,nds) <- xss]))
      DefNonRec d -> do ldef <- monLetDef False d
                        return $ \k -> ldef (\(xds,yds,nds) -> k (map DefNonRec (xds ++ yds ++ nds)))

monLetDef :: Bool -> Def -> Mon (TransX ([Def],[Def],[Def]) Expr)
monLetDef recursive def
  = withCurrentDef def $
    do monk <- getMonType (defType def)
       -- monTraceDoc $ \env -> text "analyze typex: " <+> ppType env (defType def) <> text ", result: " <> text (show (monk,defSort def)) -- <--> prettyExpr env (defExpr def)
       if ((monk == PolyMon {-|| monk == MixedMon-}) && isDupFunctionDef (defExpr def))
        then monLetDefDup monk recursive def 
        else do -- when (monk == PolyMon) $ monTraceDoc $ \env -> text "not a function definition but has mon type" <+> ppType env (defType def)
                expr' <- monExpr' True (defExpr def) -- don't increase depth
                return $ \k -> expr' (\xx -> k ([def{defExpr = xx}],[],[]))
                         -- \k -> k [def{ defExpr = expr' id}]

monLetDefDup :: MonTypeKind -> Bool -> Def -> Mon (TransX ([Def],[Def],[Def]) Expr)
monLetDefDup monk recursive def
  = do let teffs = let (tvars,_,rho) = splitPredType (defType def)
                   in -- todo: we use all free effect type variables; that seems too much. 
                      -- we should use the ones that caused this to be mon-translated and
                      -- return those as part of MonPoly or MonAlways
                      freeEffectTVars rho

       -- monTraceDoc (\env -> text "mon translation") 
       exprMon'    <- withMonTVars teffs $ monExpr' True (defExpr def)
       -- monTraceDoc (\env -> text "fast translation: free:" <+> tupled (niceTypes env (defType def:map TVar teffs)))
       exprNoMon'  <- withPureTVars teffs $ monExpr' True (defExpr def)

       return $ \k -> 
        exprMon' $ \exprMon -> 
        exprNoMon' $ \exprNoMon ->           
         let createDef name expr
              = let tname    = TName name (defType def)
                    (n,m)    = getArity (defType def)
                    var      = Var tname (InfoArity n m)
                    expr'    = if (recursive) 
                                 then [(defTName def, var)] |~> expr
                                 else expr
                in (def{ defName = name, defExpr = expr' }, var)
             nameMon  = makeHiddenName "mon" (defName def)
             nameNoMon= makeHiddenName "fast" (defName def)
             (defMon,varMon)   = createDef nameMon (exprMon)     
             (defNoMon,varNoMon) = createDef nameNoMon (exprNoMon)

             defPick  = def{ defExpr = exprPick }
             exprPick = case simplify (defExpr defMon) of -- assume (forall<as>(forall<bs> ..)<as>) has been simplified by the mon transform..
                          TypeLam tpars (Lam pars eff body) | length pars > 0 -> TypeLam tpars (Lam pars eff (bodyPick tpars pars))
                          Lam pars eff body                 | length pars > 0 -> Lam pars eff (bodyPick [] pars)
                          _ -> failure $ "Core.Mon.monLetDefDup: illegal mon transformed non-function?: " ++ show (prettyDef defaultEnv def) 

             bodyPick :: [TypeVar] -> [TName] -> Expr
             bodyPick tpars pars 
              = let tnameK = head (reverse pars)
                in makeIfExpr (App (TypeApp varValidK [typeOf tnameK]) [Var tnameK InfoNone])
                              (callPick varMon tpars pars) 
                              (callPick varNoMon tpars (init pars))
             
             callPick :: Expr -> [TypeVar] -> [TName] -> Expr
             callPick var tpars pars
              = let typeApp e = (if null tpars then e else TypeApp e (map TVar tpars))                    
                in App (typeApp var) [Var par InfoNone | par <- pars]

         in k ([defMon],[defNoMon],[defPick])

-- is  this a function definition that may need to be duplicated with a
-- plain and mon-translated definition?
isDupFunctionDef :: Expr -> Bool
isDupFunctionDef expr
  = case expr of
      TypeLam tpars (Lam pars eff body) | length pars > 0 -> True
      Lam pars eff body                 | length pars > 0 -> True
      TypeApp (TypeLam tvars body) tps  | length tvars == length tps
        -> isDupFunctionDef body
      TypeLam tpars (TypeApp body tps)  | length tpars == length tps 
         -> isDupFunctionDef body
      _ -> False



simplify :: Expr -> Expr
simplify expr
  = case expr of
      App (TypeApp (Var openName _) [eff1,eff2]) [arg]  
        | getName openName == nameEffectOpen && matchType eff1 eff2
        -> simplify arg
      TypeApp (TypeLam tvars body) tps  | length tvars == length tps
        -> simplify (subNew (zip tvars tps) |-> body)
      _ -> expr


monTrans :: (a -> Mon (TransX b c)) -> [a] -> Mon (TransX [b] c)
monTrans f xs
  = case xs of
      [] -> return $ \k -> k []
      (x:xx) -> do x'  <- f x
                   xx' <- monTrans f xx
                   return $ \k -> x' (\y -> xx' (\ys -> k (y:ys)))




applies :: [Trans a] -> ([a] -> a) -> a
applies [] f = f []
applies (t:ts) f 
  = t (\c -> applies ts (\cs -> f (c:cs)))

monTName :: TName -> Mon TName
monTName (TName name tp)
  = do -- tp' <- monTypeX tp
       return (TName name tp)


varValidK :: Expr
varValidK 
  = let typeVar = TypeVar 1 kindStar Bound
    in  Var (TName nameIsValidK (TForall [typeVar] [] (TFun [(nameNil,TVar typeVar)] typeTotal typeBool)))
            (Core.InfoExternal [(JS,"(#1 !== undefined)")])

ensureK :: TName -> TName -> (Expr -> Expr)
ensureK tname@(TName name tp) namek body
  = let expr = App (Var (TName nameEnsureK (TFun [(nameNil,tp)] typeTotal tp)) 
                  (Core.InfoExternal [(JS,"(#1 || $std_core.id)")])) [Var namek InfoNone]
        def = Def name tp expr Private DefVal rangeNull ""
    in Let [DefNonRec def] body

varK tp effTp resTp    = Var (tnameK tp effTp resTp) InfoNone -- (InfoArity 0 1)
tnameK tp effTp resTp  = tnameKN "" tp effTp resTp
tnameKN post tp effTp resTp = TName (postpend post nameK) (typeK tp effTp resTp)
typeK tp effTp resTp   = TSyn (TypeSyn nameTpCont (kindFun kindStar (kindFun kindEffect (kindFun kindStar kindStar))) 0 Nothing) 
                          {- [tp,effTp,resTp]
                           (TFun [(nameNil,tp)] effTp resTp) -}
                           [tp, effTp, tp]
                           (TFun [(nameNil,tp)] effTp tp)
                          -- TFun [(nameNil,tp)] typeTotal typeYld
 

nameK = newHiddenName "k"
nameX = newHiddenName "x"

varApplyK k x
  = let (Just (_,effTp,resTp)) = splitFunType (typeOf k)
        tp = typeFun [(nameNil,typeOf k),(nameNil,typeOf x)] effTp resTp
        applyK = Var (TName nameApplyK tp)
                     (Core.InfoExternal [(JS,"(#1||$std_core.id)(#2)")]) -- InfoArity (3,2)
    in App applyK [k,x]

appBind :: Type -> Effect ->  Type -> Expr -> Expr -> Expr
appBind tpArg tpEff tpRes arg cont
  = case arg of
      -- optimize: bind( lift(argBody), cont ) -> cont(argBody)
      App (TypeApp (Var v _) [_]) [argBody] | getName v == nameLift
        -> App cont [argBody]
      _ -> case cont of
            Lam [aname] eff (Var v _) | getName v == getName aname
              -> arg
            _ -> App (TypeApp (Var (TName nameBind typeBind) (InfoArity 3 2)) [unEff tpArg, unEff tpRes, tpEff]) [arg,cont]

unEff :: Type -> Type
unEff tp
  = case tp of
      TApp (TCon (TypeCon eff _)) [t]  | nameTpYld == eff -> t
      _ -> tp

typeBind :: Type
typeBind
  = TForall [tvarA,tvarB,tvarE] [] 
      (TFun [(nameNil,typeYld (TVar tvarA)),
             (nameNil,TFun [(nameNil,TVar tvarA)] (TVar tvarE) (typeYld (TVar tvarB)))]
            (TVar tvarE) (typeYld (TVar tvarB)))


appLift :: Expr -> Expr
appLift arg
  = let tp = typeOf arg        
    in App (TypeApp (Var (TName nameLift typeLift) (InfoArity 1 1)) [tp]) [arg]


typeLift :: Type
typeLift
  = TForall [tvarA] [] (TFun [(nameNil,TVar tvarA)] typeTotal (typeYld (TVar tvarA)))

typeYld :: Type -> Type
typeYld tp
  = TApp (TCon (TypeCon nameTpYld (kindFun kindStar kindStar))) [tp]

isTypeYld tp
  = case tp of
      TApp (TCon (TypeCon name _)) [_] -> name == nameTpYld
      _ -> False

tvarA :: TypeVar
tvarA = TypeVar 0 kindStar Bound      

tvarB :: TypeVar
tvarB = TypeVar 1 kindStar Bound      

tvarE :: TypeVar
tvarE = TypeVar 2 kindEffect Bound      


{--------------------------------------------------------------------------
  Check if expressions need monadic translation
--------------------------------------------------------------------------}  

-- Some expressions always need mon translation
isAlwaysMon :: Expr -> Bool
isAlwaysMon expr
  = case expr of
      TypeApp e _ -> isAlwaysMon e
      Var v _     -> getName v == nameYieldOp || getName v == nameUnsafeTotal -- TODO: remove these special cases?
      _ -> False

-- Some expressions never need mon translation
isNeverMon :: Expr -> Bool
isNeverMon expr
  = case expr of
      TypeApp e _ -> isNeverMon e
      Var v _     -> getName v == canonicalName 1 nameDeref --TODO: remove special case?
      _ -> False

-- Does this definition need any mon translation (sometimes deeper inside)
needsMonDef :: Def -> Mon Bool
needsMonDef def
  = do t <- needsMonType (defType def)
       if (t) then return True
        else needsMonExpr (defExpr def)
       
needsMonExpr :: Expr -> Mon Bool
needsMonExpr expr
  = case expr of
      App (TypeApp (Var open _) [_, effTo]) [_] | getName open == nameEffectOpen
        -> needsMonEffect effTo
      App f args 
        -> anyM needsMonExpr (f:args)
      Lam pars eff body
        -> orM [needsMonEffect eff, needsMonExpr body]
      
      TypeApp (TypeLam tpars body) targs
        -> do b1 <- anyM needsMonType targs
              if (b1 || any (isKindEffect . getKind) tpars)
               then return True
               else needsMonExpr (subNew (zip tpars targs) |-> body)
      TypeApp (Var tname info) targs
        -> orM [anyM needsMonType targs, needsMonType (typeOf expr)]                    
      
      TypeApp body targs
        -> orM [anyM needsMonType targs, needsMonExpr body]
      TypeLam tpars body
        -> if (any (isKindEffect . getKind) tpars) then return True
            else withRemoveTVars tpars $ needsMonExpr body
      Let defs body
        -> orM [anyM needsMonDefGroup defs, needsMonExpr body]
      Case exprs bs
        -> orM [anyM needsMonExpr exprs, anyM needsMonBranch bs]
      _ -> needsMonType (typeOf expr) -- because instantiating polymorphic variables may need translation

needsMonDefGroup defGroup
  = case defGroup of
      DefRec defs -> anyM needsMonDef defs
      DefNonRec def -> needsMonDef def

needsMonBranch (Branch pat guards)
  = anyM needsMonGuard  guards

needsMonGuard (Guard g e)
  = anyM needsMonExpr [g,e]

anyM :: (a -> Mon Bool) -> [a] -> Mon Bool
anyM f xs = orM (map f xs)

orM :: [Mon Bool] -> Mon Bool
orM xs 
  = case xs of
      [] -> return False
      (x:xx) -> do b <- x
                   if (b) then return True else orM xx

-- Is the type a function with a handled effect?
needsMonType :: Type -> Mon Bool
needsMonType tp
  = do monk <- getMonType tp 
       return (monk /= NoMon)

needsMonEffect :: Effect -> Mon Bool
needsMonEffect eff
  = do monk <- getMonEffect eff 
       return (monk /= NoMon)

data MonTypeKind 
  = NoMon      -- no mon type
  | AlwaysMon  -- always mon translated
  | PolyMon    -- polymorphic in mon: needs fast and monadic version
  deriving (Eq,Ord,Show)


-- Is the type a function with a handled effect?
getMonType :: Type -> Mon MonTypeKind
getMonType tp
  | isKindEffect (getKind tp) = getMonEffect tp
  | otherwise =
    case expandSyn tp of
      TForall vars preds t -> withRemoveTVars vars $ getMonType t
      TFun pars eff res    -> getMonEffect eff 
      _ -> return NoMon


getMonEffect :: Effect -> Mon MonTypeKind
getMonEffect eff
  = do pureTvs <- getPureTVars
       monTvs <- getMonTVars
       return (needMonEffect pureTvs monTvs eff)

getMonTVar :: Type -> Mon MonTypeKind
getMonTVar tp
  = do pureTvs <- getPureTVars
       monTvs <- getMonTVars
       return (needMonTVar pureTvs monTvs tp)




needMonEffect :: Tvs -> Tvs -> Effect -> MonTypeKind
needMonEffect pureTvs monTvs eff
  = let (ls,tl) = extractEffectExtend eff 
    in if (any (\l -> case getHandledEffect l of
                        Just ResumeMany -> True
                        _ -> False) ls)
        then AlwaysMon 
        else needMonTVar pureTvs monTvs tl

needMonTVar :: Tvs -> Tvs -> Type -> MonTypeKind
needMonTVar pureTvs monTvs tp
  = case expandSyn tp of
      TVar tv | isKindEffect (typevarKind tv) 
         -> let isPure = tvsMember tv pureTvs
                isMon  = tvsMember tv monTvs
            in if (isPure) then NoMon
                else if (isMon) then AlwaysMon
                else PolyMon
      _  -> NoMon


freeEffectTVars :: Type -> [TypeVar]
freeEffectTVars tp
  = filter (isKindEffect . getKind) (tvsList (ftv tp))

{--------------------------------------------------------------------------
  Mon monad
--------------------------------------------------------------------------}  
newtype Mon a = Mon (Env -> State -> Result a)

data Env = Env{ monadic:: Bool, currentDef :: [Def], 
                pureTVars :: Tvs, monTVars :: Tvs, 
                prettyEnv :: Pretty.Env }

data State = State{ uniq :: Int }

data Result a = Ok a State

runMon :: Monad m => Pretty.Env -> Int -> Mon a -> m a
runMon penv u (Mon c)
  = case c (Env False [] tvsEmpty tvsEmpty penv) (State u) of
      Ok x _ -> return x

instance Functor Mon where
  fmap f (Mon c)  = Mon (\env st -> case c env st of 
                                      Ok x st' -> Ok (f x) st')
                                                      
instance Applicative Mon where
  pure  = return
  (<*>) = ap                    

instance Monad Mon where
  return x      = Mon (\env st -> Ok x st)
  (Mon c) >>= f = Mon (\env st -> case c env st of 
                                    Ok x st' -> case f x of 
                                                   Mon d -> d env st' )

instance HasUnique Mon where
  updateUnique f = Mon (\env st -> Ok (uniq st) st{ uniq = (f (uniq st)) })
  setUnique  i   = Mon (\env st -> Ok () st{ uniq = i} )

withEnv :: (Env -> Env) -> Mon a -> Mon a
withEnv f (Mon c)
  = Mon (\env st -> c (f env) st)

getEnv :: Mon Env
getEnv 
  = Mon (\env st -> Ok env st)

updateSt :: (State -> State) -> Mon State
updateSt f
  = Mon (\env st -> Ok st (f st))

withCurrentDef :: Def -> Mon a -> Mon a
withCurrentDef def 
  = -- trace ("mon def: " ++ show (defName def)) $
    withEnv (\env -> env{currentDef = def:currentDef env})

withMonadic :: Bool -> Mon a -> Mon a
withMonadic b mon
  = withEnv (\env -> env{ monadic = b } ) mon

isMonadic :: Mon Bool
isMonadic
  = do env <- getEnv
       return (monadic env)

withRemoveTVars :: [TypeVar] -> Mon a -> Mon a
withRemoveTVars vs mon
  = let tvs = tvsNew vs
    in withEnv (\env -> env{ pureTVars = tvsDiff (pureTVars env) tvs, monTVars =tvsDiff (monTVars env) tvs}) $
       do mon

withPureTVars :: [TypeVar] -> Mon a -> Mon a
withPureTVars vs mon
  = withEnv (\env -> env{ pureTVars = tvsUnion (tvsNew vs) (pureTVars env)}) $
    do -- env <- getEnv
       -- monTraceDoc $ \penv -> text "with pure tvars:" <+> tupled (niceTypes penv (map TVar (tvsList (pureTVars env))))
       mon

withMonTVars :: [TypeVar] -> Mon a -> Mon a
withMonTVars vs mon
  = withEnv (\env -> env{ monTVars = tvsUnion (tvsNew vs) (monTVars env)}) $
    do -- env <- getEnv
       -- monTraceDoc $ \penv -> text "with mon tvars:" <+> tupled (niceTypes penv (map TVar (tvsList (monTVars env))))
       mon

getPureTVars :: Mon Tvs
getPureTVars
  = do env <- getEnv
       return (pureTVars env)  

isPureTVar :: TypeVar -> Mon Bool
isPureTVar tv 
  = do env <- getEnv
       return (tvsMember tv (pureTVars env))


getMonTVars :: Mon Tvs
getMonTVars
  = do env <- getEnv
       return (monTVars env)  

isMonTVar :: TypeVar -> Mon Bool
isMonTVar tv 
  = do env <- getEnv
       return (tvsMember tv (monTVars env))


monTraceDoc :: (Pretty.Env -> Doc) -> Mon ()
monTraceDoc f
  = do env <- getEnv
       monTrace (show (f (prettyEnv env)))

monTrace :: String -> Mon ()
monTrace msg
  = do env <- getEnv
       trace ("mon: " ++ show (map defName (currentDef env)) ++ ": " ++ msg) $ return ()



monType :: Type -> Type
monType tp
  = case tp of
      TForall tvs preds t -> TForall tvs preds (monType t)
      TFun pars eff res   -> let pars' = [(name,monType pt) | (name,pt) <- pars]
                                 eff'  = monType eff
                                 res'  = monType res
                                 res'' = if (needMonEffect tvsEmpty tvsEmpty eff' /= NoMon && not (isTypeYld res'))
                                          then typeYld res' else res'
                             in TFun pars' eff' res''
      TApp t ts           -> TApp (monType t) (map monType ts)
      TSyn syn ts t       -> TSyn syn (map monType ts) (monType t)
      _                   -> tp                            