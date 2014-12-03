{-# LANGUAGE TemplateHaskell #-}
{- Generate GPIR code from AST 
 - this module is temporary for playing around with the language
 - and pretty printers. In the final version the AST will go
 - through transformations and type/scope checking before
 - reaching this stage-}


module GPC.CodeGen (genCode) where

import Control.Lens
import Control.Applicative hiding ((<|>), many, optional, empty)
import Data.Char
--import Text.PrettyPrint.Leijen
import Control.Monad.State.Lazy
import qualified Data.Map as M
import GPC.AST
import GPC.GPIRAST


type VarTable = M.Map Ident Type
type ConstVarTable = M.Map Ident Literal
type FunTable = M.Map Ident SymbolTree

data CodeGen = CodeGen {
   _funTable :: FunTable,  -- ^ Store symbol tree for functions
   _constTable :: ConstVarTable
}

-- Create lenses to access Block fields easier
makeLenses ''CodeGen

type GenState a = StateT CodeGen (Either String) a 

isAssign :: TopLevel -> Bool
isAssign tl = case tl of 
    TLAssign _ -> True
    _ -> False

isObject :: TopLevel -> Bool
isObject tl = case tl of
    TLObjs _ -> True
    _ -> False

genGPIR :: Program -> Either String SymbolTree
genGPIR (Program tls) = case runStateT (genTopLevel tls) initial of 
    Left s -> Left s
    (Right (tl, _)) -> Right $ tl
 where initial = CodeGen M.empty M.empty


genTopLevel :: [TopLevel] -> GenState SymbolTree
genTopLevel tls = do
    genTLAssigns tls 
    let tls' = filter (\x -> not (isAssign x || isObject x)) tls
    symbolTrees <- mapM genTopLevelStmt tls'
    return $ SymbolList False symbolTrees


-- | Generate GPIR from Top Level statements
genTopLevelStmt :: TopLevel -> GenState SymbolTree
genTopLevelStmt tl = case tl of
      (Func _ ident args (BlockStmt stmts)) -> genFunc ident (map snd args) stmts
      (TLConstructObjs cObjs) -> genTLConstructObjs cObjs
      _ -> lift $ Left $ "Compiler error, shouldn't contain Top Level Assignments or Object Decls"

-- | Generate all Top Level Assignments
genTLAssigns :: [TopLevel] -> GenState ()
genTLAssigns tls = mapM_ genTLAssign $ filter isAssign tls
         

genTLAssign :: TopLevel -> GenState ()
genTLAssign (TLAssign (Assign _ ident expr)) = case expr of
    (ExpLit l) -> do         
        cTable <- use constTable
        assign constTable $ M.insert ident l cTable 
    _ -> lift $ Left $ "Compiler error, in top level assignment code generation"  
genTLAssign _ = lift $ Left $ "Not top level Assignment statement"



genTLConstructObjs :: ConstructObjs -> GenState SymbolTree
genTLConstructObjs (ConstructObjs var libName cName exprs) =  
    case var of  
        (VarIdent ident) -> do
            cTable <- use constTable
            args <- mapM checkConst exprs 
            let constructor = Symbol $ GOpSymbol $ 
                            MkOpSymbol False ("dummy", 0) (show libName) (show cName) (show cName)
            args <- mapM checkConst exprs
            let args' = map (\x -> Symbol (ConstSymbol True (show x))) args
            return $ SymbolList False (constructor : args')

        -- TODO work out how to map
        (VarArrayElem ident _) -> do
            cTable <- use constTable
            args <- mapM checkConst exprs 
            let constructor = Symbol $ GOpSymbol $ 
                            MkOpSymbol False ("dummy", 0) (show libName) (show cName) (show cName)
            args <- mapM checkConst exprs
            let args' = map (\x -> Symbol (ConstSymbol True (show x))) args
            return $ SymbolList False (constructor : args')



genFunc :: Ident -> [Ident] -> [Stmt] -> GenState SymbolTree 
genFunc name args stmts = error "dummy" 

checkConst :: Expr -> GenState Literal
checkConst exp = case exp of 
    (ExpLit l) -> return l
    _ -> lift $ Left $ "Expected constant expression"


-- TODO remove
genCode = error "dummy"

{-


nestLevel = 4 -- |Number of spaces to nest

-- | Concatonate a list of Docs with hcat
concatMapDocs :: (a -> Doc) -> [a] -> Doc
concatMapDocs f ds = hcat $ map f ds 


-- |Generate GPIR code from Program AST
genCode :: Program -> String
genCode (Program xs) = show doc
 where doc = concatMapDocs genTopLevel xs


-- Generate code from Top Level statements
genTopLevel :: TopLevel -> Doc
--genTopLevel (TlStmt ss) = genStmt ss
genTopLevel (Func _ (Ident n) args (BlockStmt rest)) = case args of
    -- Simple begin label for no argument functions
    [] -> letExp $ label (text n) $ begin $ concatMapDocs genStmt rest
    -- Need to generate lambda for functions with arguments
    _  -> letExp $ label (text n) $ lambda (map text vars) $ 
            begin $ concatMapDocs genStmt rest
 where vars = map (\(Type t, Ident i) -> i) args
 

-- |Generate code for statements
genStmt :: Stmt -> Doc
genStmt (FunCallStmt (FunCall (Ident n) args)) = 
    apply (text n) $ foldl (<+>) empty $ map genExpr args
genStmt (AssignStmt (Assign _ (Ident name) ex)) = 
    assign (text name) $ genExpr ex
genStmt (Seq (BlockStmt s)) = letExp $ concatMapDocs genStmt s
genStmt (If e s) =  ifStmt e s
genStmt (IfElse e s1 s2) = ifElseStmt e s1 s2 
genStmt (Return e) = genReturn $ genExpr e 
genStmt (BStmt (BlockStmt ss)) = concatMapDocs genStmt ss
        
-- |Generate code for expressions
genExpr :: Expr -> Doc
genExpr (ExpLit l) = genLit l
genExpr (ExpFunCall (FunCall (Ident n) args)) = 
    apply (text n) $ foldl (<+>) empty $ map genExpr args
genExpr (ExpIdent (Ident s)) = text s 


-- | Generate Literal 
genLit :: Literal -> Doc
genLit l =  (char '\'') <> text (genLit' l)
 where   
    genLit' :: Literal -> String
    genLit' (Str s) = "\"" ++ s ++ "\""
    genLit' (Ch  c) = show c
    genLit' (Bl  b) = map toLower (show b)
    genLit' (Number n) = case n of
        Left i -> show i
        Right d -> show d


-- | Generate apply
apply :: Doc -> Doc -> Doc
apply n s = deferParens $ text "apply" <+> n <> s

ifStmt :: Expr -> Stmt -> Doc
ifStmt cond ex = parens' $ text "if" <+> (parens $ genExpr cond) <> thenStmt 
 where thenStmt = deferParens $ genStmt ex 

ifElseStmt :: Expr -> Stmt -> Stmt -> Doc
ifElseStmt cond ex elStmt= 
    parens' $ text "if" <+> (parens $ genExpr cond) <> thenStmt <> elseStmt
 where 
    thenStmt = deferParens $ genStmt ex 
    elseStmt = deferParens $ genStmt elStmt

-- | Generate return
genReturn :: Doc -> Doc
genReturn s = deferParens $ text "return" <+> s

-- | Generate lambda
lambda :: [Doc] -> Doc -> Doc
lambda xs s = parens $ text "lambda" <+> vars <+> s
 where vars = foldl1 (<+>) $ map (\m -> char '\'' <> m) xs

-- | Assign expression to variable
assign :: Doc -> Doc -> Doc
assign n s = deferParens $ text "assign" <+> n <+> s

-- | Generate Label
label :: Doc -> Doc -> Doc
label n s = deferParens $ text "label" <+> n <+> s

-- | Generate Expression
letExp :: Doc -> Doc
letExp s =  parens' $ text "let" <+> s 

-- | Generate begin, returns value of last expression
begin :: Doc -> Doc
begin s = parens' $ text "begin" <+> s

-- |Parens to defer evaluation
deferParens :: Doc -> Doc
deferParens s = nest' 4 $ char '\'' <> parens s

parens' x = nest' 4 $ parens x

nest' :: Int -> Doc -> Doc
nest' n d = text "" <$> nest n d
-}
