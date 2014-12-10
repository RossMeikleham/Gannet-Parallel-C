{-# LANGUAGE TemplateHaskell #-}

{- Check types and scope of identifiers -}
module GPC.TypeScopeChecker(
    getTypeExpr,injectConstants, reduceExpr, runTypeChecker) where


import qualified Data.Map as M
import Data.Bits
import Control.Applicative hiding ((<|>), many, optional, empty)
import Control.Monad.Except
import Control.Monad.State.Lazy
import Control.Error.Util
import Control.Lens
import GPC.AST

type VarTable = M.Map Ident Type
type ConstVarTable = M.Map Ident Literal
type FunTable = M.Map Ident (Type, [Type])


boolType = NormalType "bool"
intType = NormalType "int"
--strType = Type "string"
--chType = Type "char"
--doubleType = Type "double"

isPointer :: Type -> Bool
isPointer (PointerType _) = True
isPointer _ = False

data MainBlock = MainBlock {
    _tlFuncDefs :: FunTable, -- ^ Function Definitions
    _tlConstVars :: ConstVarTable, -- ^ Top Level Constant Variable values
    _tlConstVarTypes :: VarTable -- ^ Top Level Constant variable types
} deriving (Show)


data CodeBlock = CodeBlock {
    _currentFun :: Ident, -- ^ Name of Function block is in
    _funcDefs :: FunTable, -- ^ Function names and return/argument types
    _prevVars :: VarTable, -- ^ Identifiers visible in current scope with types
    _curVars :: VarTable , -- ^ Identifiers declared in current scope
    _constVars :: ConstVarTable  -- ^ Identifiers visible from current scope which
                                        -- ^ evaluate to a constant value
} deriving (Show)


-- Create lenses to access Block fields easier
makeLenses ''MainBlock 
makeLenses ''CodeBlock


-- Monad Transformer combining State with Either
-- when doing type checking if a failure occurs
-- we can return an error String
type GenericBlockState a b = StateT a (Either String) b
type CodeState a = GenericBlockState MainBlock a
type BlockState a = GenericBlockState CodeBlock a


-- | Perform Type/Scope checking, and simple expression reduction
-- | Returns either an error message or the Reduced GPC AST
runTypeChecker :: Program -> Either String Program
runTypeChecker (Program tls) = case runStateT (evalTLStmts tls) initialBlock of
 Left s -> Left s
 (Right (tl, _)) -> Right $ Program tl
 where initialBlock = MainBlock M.empty M.empty M.empty


-- | Type Check all top level statements
evalTLStmts :: [TopLevel] -> CodeState [TopLevel]
evalTLStmts tls = mapM evalTLStmt tls


-- | Type check a given top level statement
evalTLStmt :: TopLevel -> CodeState TopLevel
evalTLStmt tl = case tl of
    (TLAssign a) -> TLAssign <$> evalTLAssign a
    (Func gType ident args stmts) -> evalFunc gType ident args stmts
    (TLObjs objects) -> TLObjs <$> evalObjs objects
    (TLConstructObjs cObjs) -> TLConstructObjs <$> evalConstruct cObjs


-- | Type check object initializations
evalConstruct :: ConstructObjs -> CodeState ConstructObjs
evalConstruct (ConstructObjs var libName cName exprs) = do
    cVars <- use tlConstVars
    tVars <- use tlConstVarTypes

    -- Check expressions for Constructor are constant 
    reducedExprs <- lift $ mapM (\e ->reduceExpr tVars $ injectConstants cVars e) exprs
    _ <- lift $ mapM (getTypeExpr tVars M.empty) reducedExprs
    mapM_ checkConstantExpr reducedExprs

    case var of 
        (VarIdent _) ->  
            return $ ConstructObjs var libName cName reducedExprs

        (VarArrayElem ident expr) -> do -- Check indexed expression           
            reducedExpr <- lift $ reduceExpr tVars $ injectConstants cVars expr
            exprType <- lift $ getTypeExpr tVars M.empty reducedExpr
            checkType intType exprType
            checkConstantExpr reducedExpr
            return $ ConstructObjs (VarArrayElem ident reducedExpr) libName cName reducedExprs


-- | Type check object declarations
evalObjs :: Objects -> CodeState Objects
evalObjs objs@(Objects _ _ var) = do 
    cVars <- use tlConstVars
    tVars <- use tlConstVarTypes
    
    case var of
        -- Single Object, check identifier isn't already in scope
        (VarIdent ident) -> do
            if ident `M.notMember` tVars then do
                assign tlConstVarTypes $ M.insert ident (NormalType "object") tVars 
                return objs
            else multipleInstance ident

        -- Static Array of Objects, check type of array size, check size
        -- is a constant, and that that identifier for the array isn't already in scope
        (VarArrayElem ident expr) -> do
            if ident `M.notMember` tVars then do
                reducedExpr <- lift $ reduceExpr tVars $ injectConstants cVars expr
                exprType <- lift $ getTypeExpr tVars M.empty reducedExpr
                checkType intType exprType
                checkConstantExpr reducedExpr
                assign tlConstVarTypes $ M.insert ident (NormalType "objArray") tVars
                return $ objs {objVar = (VarArrayElem ident reducedExpr)}
            else multipleInstance ident
 where          
    multipleInstance ident = lift $ Left $ (show ident) ++ " has already been defined " ++ 
        "in scope, cannot redefine it"      


-- | Type Check top level assignment
evalTLAssign :: Assign -> CodeState Assign
evalTLAssign (Assign typeG ident expr) = do
    cVars <- use tlConstVars
    tVars <- use tlConstVarTypes
    reducedExpr <- lift $ reduceExpr tVars $ injectConstants cVars expr
 
    case reducedExpr of
        (ExpLit l) -> do

            exprType <- lift $ getTypeExpr tVars M.empty reducedExpr 
            -- Check Types match and Variable is Single instance
            if exprType == typeG then 
                if ident `M.notMember` tVars then do -- Update State
                  assign tlConstVars $ M.insert ident l cVars
                  assign tlConstVarTypes $ M.insert ident typeG tVars
                  return $ Assign typeG ident reducedExpr
                else multipleInstance 
            else conflictingTypes exprType

        _ -> notConstant
                           
 where 
    multipleInstance = lift $ Left $ (show ident) ++ " has already been defined " ++ 
        "in scope, cannot redefine it" 
    conflictingTypes exprType = lift $ Left $ show (ident) ++ "is defined as type" ++ 
        (show typeG) ++ " but assignment evaluates to type " ++ (show exprType)
    notConstant = lift $ Left $ "Top level assignment are expected to be constant, " ++ 
        (show ident) ++ "is not constant"


-- | Type check Function                          
evalFunc :: Type -> Ident -> [(Type, Ident)] -> BlockStmt -> CodeState TopLevel
evalFunc typeG ident args (BlockStmt stmts) = do
    fTable <- use tlFuncDefs
    cVars <- use tlConstVars
    varTypes <- use tlConstVarTypes
    -- Check function isn't already defined
    if ident `M.notMember` fTable
        then do
            let newFTable = M.insert ident (typeG, map fst args) fTable
            let newBlock = CodeBlock ident newFTable varTypes M.empty cVars          
            assign tlFuncDefs newFTable
            funBlock <- lift $ runBlockCheck stmts newBlock
           -- assign funcs $ M.insert ident funBlock funs
            return $ Func typeG ident args funBlock
        else lift $ Left $ "Function " ++ show (ident) ++ "occurs more than once"


-- | Run Type Checker on new code block
runBlockCheck :: [Stmt] -> CodeBlock -> Either String BlockStmt
runBlockCheck stmts cb =  case runStateT (evalStmts stmts) cb of
    Left s -> Left s
    (Right (stmts', _)) -> Right $ BlockStmt stmts'


-- | Type Check all statements in the current scope
evalStmts :: [Stmt] -> BlockState [Stmt]
evalStmts tls = mapM evalStmt tls


-- | Type check given statement    
evalStmt :: Stmt -> BlockState Stmt
evalStmt stmt = case stmt of
   (AssignStmt a) -> AssignStmt <$>  checkAssign a
   (If expr stmt') -> checkIf expr stmt'
   (IfElse expr stmt1 stmt2) -> checkIfElse expr stmt1 stmt2
   (Seq blockStmt) -> Seq <$> checkBlock blockStmt M.empty
   (BStmt blockStmt) -> BStmt <$> checkBlock blockStmt M.empty
   (Return expr) -> checkReturn expr
   (ForLoop ident expr1 expr2 expr3 stmts) -> checkForLoop ident expr1 expr2 expr3 stmts
   (MethodStmt method) -> MethodStmt <$> checkMethodCall method
   _ -> lift $ Left $ "Not implemented"


-- |Type Check Assignment Statement
checkAssign :: Assign -> BlockState Assign
checkAssign (Assign gType ident expr) = do
    ftable <- use funcDefs
    oldVtable <- use prevVars
    vTable <- use curVars
    cTable <- use constVars
    let scopeVars = vTable `M.union` oldVtable -- Gives all visible identifiers
    reducedExpr <- lift $ reduceExpr scopeVars $ injectConstants cTable expr
    if ident `M.notMember` vTable then do
        exprType <- lift $ getTypeExpr scopeVars ftable reducedExpr
        if gType == exprType then do
            -- Update Var table with new variable
            assign curVars   $ M.insert ident gType vTable
            -- Update Const Table
            assign constVars $ case expr of 
                            (ExpLit l) -> M.insert ident l cTable
                            _ -> M.delete ident cTable
            return $ Assign gType ident reducedExpr
        else typeMismatch gType exprType
    else redefine
 where
    redefine = lift $ Left $ "Error, cannot redefine " ++ (show ident) ++ " in current scope" 
    typeMismatch l r = lift $ Left $ (show ident) ++ " declared as type " ++ (show l) ++
                            "but rhs evaluates to type " ++ (show r) 


-- |Type Check If Statement
checkIf :: Expr -> Stmt -> BlockState Stmt
checkIf expr stmt = do
    fTable <- use funcDefs
    cTable <- use constVars
    scopeVars <- M.union <$> use curVars <*> use prevVars 
    exprType <- lift $ getTypeExpr scopeVars fTable expr
    reducedExpr <- lift $ reduceExpr scopeVars $ injectConstants cTable expr
    if exprType == boolType then do
        reducedStmt <- evalStmt stmt
        return $ If reducedExpr reducedStmt
    else lift $ Left $ "Expression within if is expected to be a bool " ++
        " but it evaluates to a " ++ (show exprType)


-- |Type Check If - Else Statement
checkIfElse :: Expr -> Stmt -> Stmt -> BlockState Stmt
checkIfElse expr thenStmt elseStmt = do
    reducedIf <- checkIf expr thenStmt
    reducedElse <- evalStmt elseStmt
    case reducedIf of
        (If expr1 stmt) ->
            return $ IfElse expr1 stmt reducedElse
        _ -> lift $ Left $ "Compiler error in checkIfElse"


-- | Type check for loop
checkForLoop :: Ident -> Expr -> Expr -> Expr -> BlockStmt -> BlockState Stmt
checkForLoop ident startExpr stopExpr stepExpr blockStmt = do
    cTable <- use constVars
    fTable <- use funcDefs
    scopeVars <- M.union <$> use curVars <*> use prevVars 

    startExpr' <- lift $ reduceExpr scopeVars $ injectConstants cTable startExpr
    stopExpr' <- lift $ reduceExpr scopeVars $ injectConstants cTable stopExpr
    stepExpr' <- lift $ reduceExpr scopeVars $ injectConstants cTable stepExpr

    -- Check all expressions are constant (for loops are static)
    -- Check types of each expression are all integers
    -- Then type check the for block
    let exprs = [startExpr', stopExpr', stepExpr']
    mapM_ checkConstantExpr exprs
    types <- lift $ mapM (getTypeExpr scopeVars fTable) exprs
    mapM_ (checkType intType) types

    reducedBlock <- checkBlock blockStmt (M.singleton ident intType)
    return $ ForLoop ident startExpr' stopExpr' stepExpr' reducedBlock
     

-- | Type check inner block, add to current list of inner blocks
checkBlock :: BlockStmt -> VarTable -> BlockState BlockStmt
checkBlock (BlockStmt stmts) innerTable = do
    fName <- use currentFun
    fTable <- use funcDefs
    cTable <- use constVars
    scopeVars <- M.union <$> use curVars <*> use prevVars 
    
    -- Create and type check new inner block, and add to current
    -- list of inner blocks if successful
    let newBlock = CodeBlock fName fTable scopeVars innerTable cTable   
    subBlock <- lift $ runBlockCheck stmts newBlock         
    return subBlock


-- | Type check return stmt
checkReturn :: Expr -> BlockState Stmt
checkReturn expr = do
    fName <- use currentFun
    fTable <- use funcDefs
    cTable <- use constVars
    scopeVars <- M.union <$> use curVars <*> use prevVars 
    reducedExpr <- lift $ reduceExpr scopeVars $ injectConstants cTable expr

    let notFound = "Error, function not found " ++ show (fName)

    (retType, _) <- lift $ note notFound $ M.lookup fName fTable
    exprType <- lift $ getTypeExpr scopeVars fTable expr

    if retType == exprType then
        return $ Return reducedExpr
    else
        lift $ Left $ "The return type of function " ++ (show fName) ++
            "is " ++ (show retType) ++ "but return expression evaluates to" ++
            "type " ++ (show exprType)


-- | TODO Type check method call
checkMethodCall :: MethodCall -> BlockState MethodCall
checkMethodCall a = return a


-- | Check that an expression is Constant
checkConstantExpr :: Expr -> GenericBlockState a ()
checkConstantExpr expr = case expr of
    (ExpLit _) -> modify id
    _ -> lift $ Left $ "expected constant expression"


-- | Checks that 2 given types match
checkType :: Type -> Type -> GenericBlockState a ()
checkType expected actual = 
    if expected == actual then modify id else lift $ Left $ "Expected type " ++ 
        (show expected) ++ " but expression evaluated to " ++ (show actual)


-- | Obtain Type of Expression, returns error message
-- | if types arn't consistent, or identifiers arn't in scope
getTypeExpr :: VarTable -> FunTable -> Expr -> Either String Type
getTypeExpr vtable ftable expr = case expr of
    (ExpBinOp b e1 e2) -> getTypeBinOp b e1 e2
    (ExpUnaryOp u e) -> getTypeUnOp u e
    (ExpFunCall (FunCall s exps)) -> do
        argTypes <- mapM (getTypeExpr vtable ftable) exps
        (retT, ts) <- note (notFound s) (M.lookup s ftable)
        if (length argTypes) /= (length ts)
            then Left $ "Function " ++ (show s) ++  " expects " ++ (show $ length ts) ++
                      " arguments but was given " ++ (show $ length argTypes)
            else if argTypes /= ts 
                then Left "Arguments don't evaluate to given types"
                else Right retT

    (ExpMethodCall _) -> return $ NormalType "Object"
    (ExpIdent i) -> note (notFound i) (M.lookup i vtable) 
    (ExpLit l) -> return $ NormalType $ case l of
                Str _ -> "string"
                Ch _ -> "char"
                Number (Left _) -> "int"
                Number (Right _) -> "double"
                Bl _ -> "bool"

 where notFound (Ident i) = "Identifier " ++ i ++ "not declared in scope"

       getTypeBinOp :: BinOps -> Expr -> Expr -> Either String Type
       getTypeBinOp bop e1 e2  = do
            leftType <- getTypeExpr vtable ftable e1
            rightType <- getTypeExpr vtable ftable e2
            if isPointer leftType || isPointer rightType then
                getPointerTypeBin bop leftType rightType
            else getNormalTypeBin bop leftType rightType
                

       getNormalTypeBin :: BinOps -> Type -> Type -> Either String Type
       getNormalTypeBin bop leftType rightType          
           | bop `elem` numNumNumOp = do
               if leftType /= rightType 
                   then Left "Both expressions expected to be the same type"
                   else case leftType of
                       (NormalType "int") -> return $ NormalType "int"
                       (NormalType "double") -> return $ NormalType "double"
                       _ -> Left $ "Expected integer or double type"

           | bop `elem` intIntIntOp = do                
               case (leftType, rightType) of
                   (NormalType "int", NormalType "int") -> return $ NormalType "int"
                   _ -> Left $ "Expected integer values"      

           | bop `elem` compareOp = do
               case (leftType, rightType) of
                   (NormalType "int", NormalType "int") -> return $ NormalType "bool"
                   (NormalType "double", NormalType "double") -> return $ NormalType "bool"
                   _ -> Left $ "Expected numeric values of the same type"      

           | bop `elem` boolOp = do
               case (leftType, rightType) of
                   (NormalType "bool", NormalType "bool") -> return $ NormalType "bool"
                   _ -> Left $ "Expected boolean values"    
                     
            | otherwise = Left $ "Compiler error during obtaining type of binary expression"
         where numNumNumOp = [Add, Sub, Mul, Div]        
               intIntIntOp = [Mod, BAnd, BOr, BXor, ShiftL, ShiftR]
               compareOp = [LessEq, Less, Equals, Greater, GreaterEq]
               boolOp = [And, Or]

       getPointerTypeBin :: BinOps -> Type -> Type -> Either String Type
       getPointerTypeBin bop leftType rightType
        | bop == Add = 
            if (isPointer leftType  && rightType == intType) then
                return leftType    
            else if (isPointer rightType && leftType  == intType) then
                return rightType
            else Left "Can only add Pointers to Integers"
        | bop == Sub =
            if (isPointer leftType && rightType == intType) then
                return leftType
            else Left "expected pointer type on lhs and integer type on rhs for pointer subtraction"                
        | bop `elem` [Equals, NEquals] = case (leftType, rightType) of
            ((PointerType a, PointerType b)) -> 
                if a == b then 
                    return boolType
                else Left $ "Expected pointer types to be equal, left points to " ++ (show a) ++
                          ". Right points to " ++ (show b) ++ "."
            _ -> Left "Cannot perform an equality comparison of pointer and non pointer types"

        | otherwise =  Left $ "operation " ++ (show bop) ++ " not defined for pointer types"

       getTypeUnOp :: UnaryOps -> Expr -> Either String Type
       getTypeUnOp operation e 
        | operation == Not || operation == Neg = getTypeExpr vtable ftable e >>= 
            \t -> case t of 
                (NormalType "int") -> return $ NormalType "int"
                _ -> Left "Expected integer expression"
        | operation == BNot = getTypeExpr vtable ftable e >>=
            \t -> case t of 
                (NormalType "bool") -> return $ NormalType "bool"
                _ -> Left "Expected boolean expression"

        | operation == Deref = getTypeExpr vtable ftable e >>=
             \t -> case t of
                (PointerType gType) -> return $ NormalType gType
                _ -> Left "Expected pointer type to dereference"
        
        | otherwise = Left $ "Compiler error during obtaining type of unary expression"


-- Replace all constant identifiers with their
-- constant value
injectConstants :: ConstVarTable -> Expr -> Expr
injectConstants ctable expr = case expr of
    (ExpBinOp b e1 e2) -> ExpBinOp b (injectConstants ctable e1) (injectConstants ctable e2)
    (ExpUnaryOp u e) -> ExpUnaryOp u (injectConstants ctable e)
    (ExpFunCall (FunCall s exps)) -> ExpFunCall (FunCall s (map (injectConstants ctable) exps))
    (ExpMethodCall (MethodCall obj method args)) -> 
        ExpMethodCall (MethodCall obj method (map (injectConstants ctable) args))
    (ExpIdent i) -> case M.lookup i ctable of
                                Just l ->   ExpLit l
                                Nothing ->  ExpIdent i
    (ExpLit l) -> (ExpLit l)



-- | Attempts to reduce an expression as much as possible
-- | Returns an error string if evaluated expression 
-- | is invalid or an identifier is not present in the given table
-- | otherwise returns the reduced expression
reduceExpr :: VarTable -> Expr -> Either String Expr
reduceExpr vtable expr = case expr of
    (ExpBinOp b e1 e2) -> do 
        re1 <- reduceExpr vtable e1
        re2 <- reduceExpr vtable e2 
        evaluateBinExpr b re1 re2

    (ExpUnaryOp u e) -> do 
        reducedExpr <- reduceExpr vtable e
        evaluateUnExpr u reducedExpr

    (ExpFunCall (FunCall s exps)) -> do
         rexps <- mapM (reduceExpr vtable) exps
         return $ ExpFunCall (FunCall s rexps)

    (ExpMethodCall (MethodCall obj method args)) -> do
        rexps <- mapM (reduceExpr vtable) args
        return $ ExpMethodCall (MethodCall obj method rexps)

    (ExpIdent i) -> ExpIdent <$> if M.member i vtable 
                                    then (Right i) 
                                    else (Left $ notFound i)

    (ExpLit l) -> return (ExpLit l)
 where notFound (Ident i) = "Identifier " ++ i ++ "not declared in scope"

-- | Attempts to evaluate a constant binary expression, checks the types as well
evaluateBinExpr :: BinOps -> Expr -> Expr -> Either String Expr
evaluateBinExpr b (ExpLit l1) (ExpLit l2) = (binOpTable b) l1 l2
evaluateBinExpr  b e1 e2 = return $ ExpBinOp b e1 e2


-- | Obtain binary operation to use with literal values
binOpTable :: BinOps -> (Literal -> Literal -> Either String Expr)
binOpTable b = case b of
    Add -> performBinNumOp (+)
    Sub -> performBinNumOp (-)
    Div -> performBinNumOp (/)
    Mul -> performBinNumOp (*)
    

    Mod -> performBinIntOp mod
    BAnd -> performBinIntOp (.&.) 
    BOr -> performBinIntOp (.|.)
    BXor -> performBinIntOp xor
    ShiftL -> performBinIntOp (\x y ->  shift x $ fromIntegral y)
    ShiftR -> performBinIntOp (\x y ->  shift x $ fromIntegral (-y))

    Less -> performBinCompareOp (<)
    LessEq -> performBinCompareOp (<=)
    Greater -> performBinCompareOp (>)
    GreaterEq -> performBinCompareOp (>=)
    Equals -> performBinCompareOp (==)
    NEquals -> performBinCompareOp (/=)

    And -> performBinBoolOp (&&) 
    Or -> performBinBoolOp (||)


performBinNumOp :: (Double  -> Double -> Double)  -> Literal -> Literal -> Either String Expr
performBinNumOp operation (Number (Left n1)) (Number (Left n2)) = Right litExp
 where litExp = ExpLit $ Number $ Left $ truncate $ n1' `operation` n2'
       n1' = fromIntegral n1
       n2' = fromIntegral n2


performBinNumOp operation (Number (Right n1))(Number (Right n2)) = 
    Right $ ExpLit $ Number $ Right $ n1 `operation` n2
performBinNumOp _ _ _ = Left "Error expected a numeric value" 


performBinIntOp :: (Integer -> Integer -> Integer)  -> Literal -> Literal -> Either String Expr
performBinIntOp operation (Number (Left n1)) (Number (Left n2)) = 
    Right $ ExpLit $ Number $ Left $ n1 `operation` n2
performBinIntOp _ _ _ = Left "Error expected integer types"

    
performBinCompareOp :: (Double -> Double -> Bool) -> Literal -> Literal -> Either String Expr
performBinCompareOp operation (Number (Left n1)) (Number (Left n2)) = 
    Right $ ExpLit $ Bl $ n1' `operation` n2'
 where n1' = fromIntegral n1
       n2' = fromIntegral n2


performBinCompareOp operation (Number (Right n1)) (Number (Right n2)) = 
    Right $ ExpLit $ Bl $ n1 `operation` n2 
performBinCompareOp _ _ _ = Left "Error expected either 2 ints, or 2 doubles"

    
performBinBoolOp :: (Bool -> Bool -> Bool) -> Literal -> Literal -> Either String Expr
performBinBoolOp operation (Bl b1) (Bl b2) = 
    Right $ ExpLit $ Bl $ b1 `operation` b2
performBinBoolOp _ _ _ = Left "Error expected boolean values"


-- |Attempts to evaluate a constant unary expression, check the types as
-- |well
evaluateUnExpr :: UnaryOps -> Expr -> Either String Expr
evaluateUnExpr unOp (ExpLit l) = (unOpTable unOp) l
evaluateUnExpr _ e = Right e

-- | Function table of Unary operations on literals
unOpTable u = case u of
    Not -> performUnNotOp
    Neg -> performUnNegOp
    BNot -> performUnBNotOp
    Deref -> performDerefOp


-- | Perform Boolean NOT operation on literal value
performUnNotOp ::  Literal -> Either String Expr
performUnNotOp (Bl b1) = Right $ ExpLit $ Bl $ not b1
performUnNotOp _ = Left "Error expected boolean value"

-- | Perform Negation operation on literal value
performUnNegOp :: Literal -> Either String Expr
performUnNegOp (Number (Left i)) =  Right $ ExpLit $ Number $ Left  $ negate i
performUnNegOp (Number (Right i)) = Right  $ ExpLit $ Number $ Right $ negate i
performUnNegOp _ = Left "Error expected numeric type"

-- | Perform Bitwise NOT operation on literal value
performUnBNotOp :: Literal -> Either String Expr
performUnBNotOp (Number (Left i)) = Right $ ExpLit $ Number $ Left $ complement i
performUnBNotOp _ = Left "Error expected integer value"

-- | Perform dereference operation on literal value
performDerefOp :: Literal -> Either String Expr
performDerefOp _ =  Left $ "Error cannot derefence literal value"

