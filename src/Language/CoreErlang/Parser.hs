{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}

-----------------------------------------------------------------------------

-----------------------------------------------------------------------------

-- |
-- Module      :  Language.CoreErlang.Parser
-- Copyright   :  (c) Henrique Ferreiro García 2008
--                (c) David Castro Pérez 2008
--                (c) Feng Lee 2020
-- License     :  BSD-style (see the LICENSE file)
-- Maintainer  :  Feng Lee <feng@emqx.io>
-- Stability   :  experimental
-- Portability :  portable
--
-- Parser for CoreErlang.
-- <http://erlang.org/doc/apps/compiler/compiler.pdf>
module Language.CoreErlang.Parser
  ( parseModule,
    ParseError,
    runLex,
  )
where

import Data.Char (chr)
import Numeric ( readOct )
import Control.Monad (liftM)
import Language.CoreErlang.Syntax
import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Language
import qualified Text.ParserCombinators.Parsec.Token as Token
import Text.ParserCombinators.Parsec.Token
  ( TokenParser,
    makeTokenParser,
  )

-- Lexical definitions

uppercase :: Parser Char
uppercase = annotated' upper

lowercase :: Parser Char
lowercase = annotated' lower

namechar :: Parser Char
namechar = annotated' $ uppercase <|> lowercase <|> digit <|> oneOf "@_"

escape :: Parser Char
escape = do char '\\'
            s <- octal <|> ctrl <|> escapechar
            return s

octal :: Parser Char
octal = do chars <- tryOctal
           let [(o, _)] = readOct chars
           return (chr o)

tryOctal :: Parser [Char]
tryOctal = choice [ try (count 3 octaldigit),
                    try (count 2 octaldigit),
                    try (count 1 octaldigit) ]

octaldigit :: Parser Char
octaldigit = oneOf "01234567"

ctrl :: Parser Char
ctrl = char '^' >> ctrlchar

ctrlchar :: Parser Char
ctrlchar = satisfy (`elem` ['\x0040'..'\x005f'])

escapechar = oneOf "bdefnrstv\"\'\\"
-- Terminals

integer :: Parser Integer
integer = do
  i <- positive <|> negative <|> decimal
  whiteSpace -- TODO: buff
  return $ i

positive :: Parser Integer
positive = do
  char '+'
  p <- decimal
  return p

negative :: Parser Integer
negative = do
  char '-'
  n <- decimal
  return $ negate n

positiveF :: Parser Double
positiveF = do
  char '+'
  p <- float
  return p

negativeF :: Parser Double
negativeF = do
  char '-'
  n <- float
  return $ negate n

sFloat :: Parser Double
sFloat = do
  i <- positiveF <|> negativeF <|> float
  whiteSpace -- TODO: buff
  return $ i

atom :: Parser Atom
atom = annotated' $ do
  char '\''
  a <- many (noneOf "\r\n\\\'" <|> escape)
  char '\''
  whiteSpace -- TODO: buff
  return $ Atom a

echar :: Parser Literal
echar = annotated' $ do
  char '$'
  c <- noneOf "\n\r\\ " <|> escape
  whiteSpace -- TODO: buff
  return $ LChar c

estring :: Parser Literal
estring = annotated' $ do
  char '"'
  s <- many $ noneOf "\n\r\\\"" <|> escape
  char '"'
  return $ LString s

variable :: Parser Var
variable = liftM Var (annotated identifier)

-- Non-terminals

emodule :: Parser (Ann Module)
emodule = annotated amodule

amodule :: Parser Module
amodule = annotated' $ do
  reserved "module"
  name <- atom
  funs <- exports
  attrs <- attributes
  fundefs <- many fundef
  reserved "end"
  return $ Module name funs attrs fundefs

exports :: Parser [FunName]
exports = annotated' $ brackets $ commaSep fname

attributes :: Parser [(Atom, Const)]
attributes = annotated' $ do
  reserved "attributes"
  brackets $ commaSep attribute

attribute :: Parser (Atom, Const)
attribute = annotated' $ do
  a <- atom
  symbol "="
  c <- constant
  return (a, c)

constant :: Parser Const
constant =
  annotated' $
    liftM CLit (try literal)
      <|> liftM CTuple (tuple constant)
      <|> liftM CList (elist constant)
      <|> liftM CMap (emap "=>" constant constant)

fundef :: Parser FunDef
fundef = annotated' $ do
  name <- annotated fname
  symbol "="
  body <- annotated lambda
  return $ FunDef name body

fname :: Parser FunName
fname = annotated' $ do
  a <- atom
  char '/'
  i <- decimal
  whiteSpace -- TODO: buff
  return $ FunName (a, i)

literal :: Parser Literal
literal =
  annotated' $
     try (liftM LFloat sFloat) <|> (liftM LInt integer)
      <|> liftM LAtom atom
      <|> nil
      <|> echar
      <|> estring

nil :: Parser Literal
nil = brackets (return LNil)

expression :: Parser Exprs
expression =
  annotated' $
    try (liftM Exprs (annotated $ angles $ commaSep (annotated sexpression)))
      <|> liftM Expr (annotated sexpression)

sexpression :: Parser Expr
sexpression =
  annotated' $
    app <|> ecatch <|> ecase <|> elet
      <|> liftM Fun (try fname {- because of atom -})
      <|> (try extfun)
      <|> lambda
      <|> letrec
      <|> liftM Binary (ebinary expression)
      <|> liftM List (try $ elist expression {- because of nil -})
      <|> liftM Lit literal
      <|> modcall
      <|> op
      <|> receive
      <|> eseq
      <|> etry
      <|> liftM Tuple (tuple expression)
      <|> (try $ liftM VMap (vmap "=>" expression expression))
      <|> (try $ liftM UMap (umap ":=" expression expression))
      <|> liftM EMap (emap "=>" expression expression)
      <|> liftM EVar variable



app :: Parser Expr
app = annotated' $ do
  reserved "apply"
  e1 <- expression
  eN <- parens $ commaSep expression
  return $ App e1 eN

ecatch :: Parser Expr
ecatch = annotated' $ do
  reserved "catch"
  e <- expression
  return $ Catch e

ebinary :: Parser a -> Parser [Bitstring a]
ebinary p = annotated' $ do
  symbol "#"
  bs <- braces (commaSep (bitstring p))
  symbol "#"
  return bs

emap :: String -> Parser k -> Parser v -> Parser (Map k v)
emap s kp vp = annotated' $ do
  symbol "~"
  l <- braces (commaSep (emapKV s kp vp))
  symbol "~"
  return $ Map l

vmap :: String -> Parser k -> Parser v -> Parser (VarMap k v)
vmap s kp vp = annotated' $ do
  symbol "~"
  symbol "{"
  l <- commaSep (emapKV s kp vp)
  symbol "|"
  m <- sexpression
  symbol "}"
  symbol "~"
  return $ VarMap l m

umap :: String -> Parser k -> Parser v -> Parser (UpdateMap k v)
umap s kp vp = annotated' $ do
  symbol "~"
  symbol "{"
  l <- commaSep (emapKV s kp vp)
  symbol "|"
  m <- sexpression
  symbol "}"
  symbol "~"
  return $ UpdateMap l m




emapKV :: String -> Parser k -> Parser v -> Parser (k, v)
emapKV s kp vp = annotated' $ do
  k <- kp
  symbol s
  v <- vp
  return (k, v)

bitstring :: Parser a -> Parser (Bitstring a)
bitstring p = annotated' $ do
  symbol "#"
  e0 <- angles p
  es <- parens (commaSep expression)
  return $ Bitstring e0 es

ecase :: Parser Expr
ecase = annotated' $ do
  reserved "case"
  e <- expression
  reserved "of"
  alts <- many1 (annotated clause)
  reserved "end"
  return $ Case e alts

clause :: Parser Alt
clause =annotated' $  do
  pat <- patterns
  g <- guard
  symbol "->"
  e <- expression
  return $ Alt pat g e

patterns :: Parser Pats
patterns = annotated' $
  try (liftM Pats (annotated $ angles $ commaSep (annotated pattern')))
    <|> liftM Pat (annotated pattern)

pattern :: Parser Pat
pattern = annotated' $
  liftM PAlias (try alias {- because of variable -}) <|> liftM PVar variable
    <|> liftM PLit (try literal {- because of nil -})
    <|> liftM PTuple (tuple pattern)
    <|> liftM PList (elist pattern)
    <|> liftM PBinary (ebinary pattern)
    <|> liftM PMap (emap ":=" pkey pattern) -- TODO: Fixme later

pattern' :: Parser Pat
pattern' =
  liftM PAlias (try alias {- because of variable -}) <|> liftM PVar variable
    <|> liftM PLit (try literal {- because of nil -})
    <|> liftM PTuple (tuple pattern)
    <|> liftM PList (elist pattern)
    <|> liftM PBinary (ebinary pattern)
    <|> liftM PMap (emap ":=" pkey pattern)

pkey :: Parser Key
pkey = annotated' $ liftM KVar variable <|> liftM KLit literal

alias :: Parser Alias
alias = do
  v <- variable
  symbol "="
  p <- pattern
  return $ Alias v p

guard :: Parser Guard
guard = annotated' $ do
  reserved "when"
  e <- expression
  return $ Guard e

elet :: Parser Expr
elet = annotated' $ do
  reserved "let"
  vars <- variables
  symbol "="
  e1 <- expression
  symbol "in"
  e2 <- expression
  return $ Let (vars, e1) e2

variables :: Parser [Var]
variables = annotated' $ do { v <- variable; return [v] } <|> (angles $ commaSep variable)

lambda :: Parser Expr
lambda = do
  reserved "fun"
  vars <- parens $ commaSep variable
  symbol "->"
  expr <- expression
  return $ Lam vars expr

extfun :: Parser Expr
extfun =annotated' $ do
  reserved "fun"
  m <- atom
  symbol ":"
  f <- fname
  return $ ExtFun m f

letrec :: Parser Expr
letrec =annotated' $ do
  reserved "letrec"
  defs <- many fundef
  reserved "in"
  e <- expression
  return $ LetRec defs e

elist :: Parser a -> Parser (List a)
elist a = annotated' $ brackets $ list a

list :: Parser a -> Parser (List a)
list el = do
  elems <- commaSep1 $ el
  option
    (L elems)
    ( do
        symbol "|"
        t <-  el
        return $ LL elems t
    )

modcall :: Parser Expr
modcall = annotated' $ do
  reserved "call"
  e1 <- expression
  symbol ":"
  e2 <- expression
  eN <- parens $ commaSep expression
  return $ ModCall (e1, e2) eN

op :: Parser Expr
op = annotated' $ do
  reserved "primop"
  a <- atom
  e <- parens $ commaSep expression
  return $ PrimOp a e

receive :: Parser Expr
receive =annotated' $  do
  reserved "receive"
  alts <- many $ annotated clause
  to <- timeout
  return $ Rec alts to

timeout :: Parser TimeOut
timeout =annotated' $  do
  reserved "after"
  e1 <- expression
  symbol "->"
  e2 <- expression
  return $ TimeOut e1 e2

eseq :: Parser Expr
eseq =annotated' $  do
  reserved "do"
  e1 <- expression
  e2 <- expression
  return $ Seq e1 e2

etry :: Parser Expr
etry = annotated' $ do
  reserved "try"
  e1 <- expression
  reserved "of"
  v1 <- variables
  symbol "->"
  e2 <- expression
  reserved "catch"
  v2 <- variables
  symbol "->"
  _ <- expression
  return $ Try e1 (v1, e1) (v2, e2)

tuple :: Parser a -> Parser [a]
tuple el = annotated' $ braces $ commaSep el

annotation :: Parser [Const]
annotation = do
  symbol "-|"
  cs <- brackets $ (commaSep constant)
  return $ cs

annotated :: Parser a -> Parser (Ann a)
annotated p = parens
  ( do
      e <- p
      cs <- annotation
      return $ Ann e cs
  )
  <|> do
    e <- p
    return $ Constr e

annotated' :: Parser a -> Parser a
annotated' p = parens
  ( do
      e <- p
      _ <- annotation
      return $ e
  )
  <|> do
    e <- p
    return $ e

lexer :: TokenParser ()
lexer =
  makeTokenParser
    ( emptyDef
        { --    commentStart = "",
          --    commentEnd = "",
          commentLine = "%",
          --    nestedComments = True,
          identStart = upper <|> char '_',
          identLetter = namechar
          --    opStart,
          --    opLetter,
          --    reservedNames,
          --    reservedOpNames,
          --    caseSensitive = True,
        }
    )

angles, braces, brackets :: Parser a -> Parser a
angles = Token.angles lexer
braces = Token.braces lexer
brackets = Token.brackets lexer

commaSep, commaSep1 :: Parser a -> Parser [a]
commaSep = Token.commaSep lexer
commaSep1 = Token.commaSep1 lexer

decimal :: Parser Integer
decimal = Token.decimal lexer

float :: Parser Double
float = Token.float lexer

identifier :: Parser String
identifier = Token.identifier lexer
------------------------------------
parens :: Parser a -> Parser a
parens =  Token.parens lexer

reserved :: String -> Parser ()
reserved = annotated' . Token.reserved lexer

symbol :: String -> Parser String
symbol =  annotated' . Token.symbol lexer

whiteSpace :: Parser ()
whiteSpace = Token.whiteSpace lexer
------------------------------------
runLex :: Show a => Parser a -> String -> IO ()
runLex p file = do
  input <- readFile file
  parseTest
    ( do
        whiteSpace
        x <- p
        eof
        return x
    )
    input
  return ()

-- | Parse of a string, which should contain a complete CoreErlang module
parseModule :: String -> Either ParseError (Ann Module)
parseModule input =
  parse
    ( do
        whiteSpace
        x <- emodule
        eof
        return x
    )
    ""
    input
