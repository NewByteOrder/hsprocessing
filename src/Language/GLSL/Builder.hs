{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FunctionalDependencies #-}

module Language.GLSL.Builder where

import           Control.Monad.State                (State, evalState,
                                                     execState, get, put,
                                                     runState)
import qualified Control.Monad.State                as State
import           Data.Array.Linear                  (Transformed (..))
import qualified Data.Array.Linear                  as A
import           Data.Array.Linear.Color.Attrs.RGBA
import           Data.Array.Linear.Color.Class
import           Data.Array.Linear.Color.Modes
import qualified Data.Char                          as Char
import           Data.Convert
import           Data.RTuple
import           Data.String                        (IsString, fromString)
import qualified Data.Vector                        as V
import           GHC.TypeLits                       (Nat)
import           GHC.TypeLits
-- import           GHCJS.Types                        (JSRef)
import qualified Graphics.Display.Object            as O
import           Graphics.Rendering.GLSL.SDF
import           Graphics.Rendering.GLSL.SDF.Utils  (sdf_utils, shader_header)
-- import           Graphics.Rendering.WebGL           (compileShader)
import           Graphics.Shading.Flat
import           Graphics.Shading.Material
import           Graphics.Shading.Pattern
import           Language.GLSL                      ()
import           Language.GLSL.DSL
import           Language.GLSL.Syntax               hiding (Uniform)
import           Math.Algebra.Boolean               hiding (Compound, Expr)
import qualified Math.Algebra.Boolean               as Bool
import           Math.Space.Dimension               (Dim (..), DimOf)
import           Math.Space.Metric.Bounded          (Bounded (..))
import           Math.Space.Metric.SDF
import           Math.Topology.Geometry.Figures
import           Prelude                            ()
import           Prologue                           hiding (Bounded, div, void,
                                                     (.=), (.>))
import           Text.PrettyPrint.HughesPJClass     (Pretty, prettyShow)




-- === StdUniforms ===


data StdUniforms = StdUniforms { _position :: A.BVec 2 Expr
                               , _colorx   :: Expr
                               } deriving (Show)
makeLenses ''StdUniforms



instance Monoid StdUniforms where
    mempty = StdUniforms { _position = A.vec2 ("p" .> "x") ("p" .> "y")
                         , _colorx   = "gl_FragColor"
                         }

-- === GLSLState ===

data Uniform t = Uniform String t deriving (Show, Functor, Traversable, Foldable)

newtype Uniform2 t = Uniform2 (UniformType t)

data UniformDecl = UniformDecl String ExternalDeclaration deriving (Show)

type family UniformType uni


class    IsUniform a     where toDecl :: Uniform a -> ExternalDeclaration
instance IsUniform Float where toDecl (Uniform n a) = uniformDecl2 n

class    IsUniformID t => IsUniform2 t where toDecl2 :: Uniform2 t -> ExternalDeclaration
instance IsUniformID t => IsUniform2 t where toDecl2 (Uniform2 a) = uniformDecl2 (reprID (Proxy :: Proxy t))


class IsUniformID t where reprID :: Proxy t -> String


instance Convertible (UniformType t) Expr
      => Convertible (Uniform2    t) Expr where convert (Uniform2 a) = convert a

--uniformDecl2 :: String -> Expr -> ExternalDeclaration
--uniformDecl2 name e = Declaration
--                    $ InitDeclaration (TypeDeclarator (FullType (Just (TypeQualSto Uniform)) (TypeSpec Nothing (TypeSpecNoPrecision Float Nothing))))
--                      [ InitDecl name Nothing $ Just e ]

-- === GLSLState ===

data GLSLState = GLSLState { _glslAST     :: Compound
                           , _stdUniforms :: StdUniforms
                           , _uniforms    :: [UniformDecl]
                           , _freeNames   :: [String]
                           } deriving (Show)
makeLenses ''GLSLState

-- Instances

class Monad m => MonadGLSL m where
    getState :: m GLSLState
    putState :: GLSLState -> m ()

instance MonadGLSL (State GLSLState) where
    getState = get
    putState = put

instance Monoid GLSLState where
    mempty = GLSLState (Compound []) mempty mempty ((\s -> ("_" <> s <> "_")) .: flip (:) <$> ("" : fmap show [0..]) <*> ['a' .. 'z'])

instance Monoid Compound where
    mempty = Compound []
    mappend (Compound a) (Compound b) = Compound $ a <> b

-- === GLSL Program ===

--newtype ProgramDesc   unis = ProgramDesc TranslationUnit deriving (Show)
data   Program t unis = Program t unis


-- === GLSL Builder ===

class GLSLBuilder t m unis | t -> unis where
    toGLSL :: t -> m unis


-- Utils

genName' :: MonadGLSL m => m String
genName' = do
    s <- getState
    let (n:ns) = view freeNames s
    putState (s & freeNames .~ ns)
    return n

genName :: MonadGLSL m => m Expr
genName = fromString <$> genName'

newName' :: MonadGLSL m => String -> m String
newName' pfx = (pfx <>) <$> genName'

newName :: MonadGLSL m => String -> m Expr
newName pfx = fromString <$> newName' pfx

withState f = do
    s <- getState
    putState $ f s

getStdUniforms = view stdUniforms <$> getState

getPosition = view position <$> getStdUniforms
getColor    = view colorx   <$> getStdUniforms

newUniform pfx a = do
    --name <- (pfx <>) <$> genName'
    name <- return pfx

    let uni = Uniform name a
    withState $ uniforms %~ (UniformDecl name (toDecl uni) :)
    return uni

newUniform2 :: (MonadGLSL m, IsUniform2 t) => t -> (UniformType t) -> m (Uniform2 t)
newUniform2 t a = do
    --name <- (pfx <>) <$> genName'
    --name <- return (show t)

    let uni = Uniform2 a
    withState $ uniforms %~ (UniformDecl "dupa" (toDecl2 uni) :)
    return uni

newUniform3 :: (MonadGLSL m, IsUniform2 t) => t -> (UniformType t) -> m (Uniform2 t)
newUniform3 t a = do
    let uni = Uniform2 a
    withState $ uniforms .~ [UniformDecl "dupa" (toDecl2 uni)]
    return uni

compileGLSL :: GLSLBuilder t (State GLSLState) u => t -> (String, u)
compileGLSL = runBuilder . toGLSL

setTUnit a = withState $ glslAST .~ a

-- === SDF Building ===


data AA = AA deriving (Show)
type instance UniformType AA = Float

instance IsUniformID AA where reprID _ = "aa"


instance Convertible a Expr => Convertible (Color RGBA a) Expr where
    convert (view wrapped -> c) = "vec4" [ convert $ c ^. A.x, convert $ c ^. A.y, convert $ c ^. A.z, convert $ c ^. A.w ]

instance MonadGLSL m => GLSLBuilder (Object 2) m (Uniform2 AA, Expr) where
    toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound (Bool.Expr (Merge expr1 expr2))))))) = do
        aa <- newUniform3 AA (0.0 :: Float)
        (u1, sdfName1) <- toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound expr1)))))
        s1 <- getState
        (u2, sdfName2) <- toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound expr2)))))
        s2 <- getState

        color <- getColor
        gMerged <- newName "sdf"

        let rest = [ val float gMerged $ "sdf_merge" [ sdfName1, sdfName2 ]
                   , color .= "vec4" [0.1, 0.1, 0.1, 0.0]
                   ]

        gExpr <- (rest <>) . snd <$> drawLayers gMerged color layers

        let newAST = (s1 ^. glslAST) <> (s2 ^. glslAST) <> compound gExpr

        setTUnit newAST
        return (aa, gMerged)

    toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound (Bool.Expr (Diff expr1 expr2))))))) = do
        aa <- newUniform3 AA (0.0 :: Float)
        (u1, sdfName1) <- toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound expr1)))))
        s1 <- getState
        (u2, sdfName2) <- toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound expr2)))))
        s2 <- getState

        color <- getColor
        gDiffed <- newName "sdf"

        let rest = [ val float gDiffed $ "sdf_subtract" [ sdfName1, sdfName2 ]
                   , color .= "vec4" [0.1, 0.1, 0.1, 0.0]
                   ]

        gExpr <- (rest <>) . snd <$> drawLayers gDiffed color layers

        let newAST = (s1 ^. glslAST) <> (s2 ^. glslAST) <> compound gExpr

        setTUnit newAST
        return (aa, gDiffed)

    toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound (Bool.Expr (Intersect expr1 expr2))))))) = do
        aa <- newUniform3 AA (0.0 :: Float)
        (u1, sdfName1) <- toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound expr1)))))
        s1 <- getState
        (u2, sdfName2) <- toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound expr2)))))
        s2 <- getState

        color <- getColor
        gIntersected <- newName "sdf"

        let rest = [ val float gIntersected $ "sdf_intersect" [ sdfName1, sdfName2 ]
                   , color .= "vec4" [0.1, 0.1, 0.1, 0.0]
                   ]

        gExpr <- (rest <>) . snd <$> drawLayers gIntersected color layers

        let newAST = (s1 ^. glslAST) <> (s2 ^. glslAST) <> compound gExpr

        setTUnit newAST
        return (aa, gIntersected)

    toGLSL (Object (O.Object (Shaded (Material layers) (Transformed xform (Bool.Compound (Bool.Val obj)))))) = do

        -- let sdf = convert obj :: SDF 2 Expr
        let sdf = obj
            -- uu :: _
            -- uu = obj

        p      <- getPosition


        color  <- getColor
        gstart <- newName "sdf"

        --aa <- newUniform "aa" (0.0 :: Float)
        aa <- newUniform3 AA (0.0 :: Float)

        let rest = [ val float gstart $ runSDF sdf p
                   , color .= "vec4" [0.1, 0.1, 0.1, 0.0]
                   ]

        xformV <- newName "xform"
        let transl = [ val mat4 xformV $ convert xform
                     , "p" .= "appTrans2D" [ "p", xformV ]
                     ]

        gExpr <- (rest <>) . snd <$> drawLayers gstart color layers

        let u = compound $ transl <> gExpr
        setTUnit u
        return (aa, gstart)


drawLayers g color []     = return (g,[])
drawLayers g color (l:ls) = do
    let drawPattern = \case
            Solid c -> do
                fill <- newName "fill"
                return (fill, [ val vec4 fill $ convert c ])

        processLayer = \case
            Fill pattern -> do
                let gtrans g = return (g,[])
                    gdraw g = do
                        (fill, glsl) <- drawPattern pattern
                        return $ glsl
                              <> [ color .= "blend" [color, "vec4" [fill .> "rgb", "sdf_aa"[g] * (fill .> "a") ]]
                                 ]
                              -- <> [ color .= "vec4" ["mix" [color .> "rgb", fill .> "rgb", "sdf_aa"[g] * (fill .> "a") ], 1.0]
                              --    ]
                return (gtrans, gdraw)

            Border rad pattern -> do
                let gtrans s = do
                        ng     <- newName "sdf"
                        return (ng, [val float ng $ "sdf_grow" [convert rad, s]])
                    gdraw s = do
                        (fill, glsl) <- drawPattern pattern
                        ng     <- newName "sdf"
                        return $ glsl
                              <> [ val float ng      $ "sdf_borderOut" [convert rad, s]
                                 , color .= "vec4" ["mix" [color .> "rgb", fill .> "rgb", "sdf_aa"[ng] * (fill .> "a") ], 1.0]
                                 ]
                return (gtrans, gdraw)

            Shadow rad exp pattern -> do
                shadow <- newName "shadow"
                let gtrans g = return (g,[])
                    gdraw g = do
                            (fill, glsl) <- drawPattern pattern
                            return $ glsl
                                  <> [ val float shadow $ "sdf_shadow" [g, convert rad, convert exp]
                                     , color .= "vec4" ["mix" [color .> "rgb", fill .> "rgb", shadow], 1.0]
                                     ]
                return (gtrans, gdraw)
    (gtrans , gdraw)  <- processLayer l
    (g',  glslGTrans) <- gtrans g
    (g'', glslBgrnd ) <- drawLayers g' color ls
    glslLayer         <- gdraw g
    return (g'', glslGTrans <> glslBgrnd <> glslLayer)

-- Right
--  (TranslationUnit
--     [ Declaration
--         (InitDeclaration
--            (TypeDeclarator
--               (FullType
--                  Nothing (TypeSpec Nothing (TypeSpecNoPrecision Float Nothing))))
--            [ InitDecl "a" Nothing (Just (FloatConstant 1.0)) ])
--     ])

-- Right
--   (TranslationUnit
--      [ FunctionDefinition
--          (FuncProt
--             (FullType
--                Nothing (TypeSpec Nothing (TypeSpecNoPrecision Void Nothing)))
--             "main"
--             [ ParameterDeclaration
--                 Nothing
--                 Nothing
--                 (TypeSpec Nothing (TypeSpecNoPrecision Void Nothing))
--                 Nothing
--             ])
--          (Compound
--             [ DeclarationStatement
--                 (InitDeclaration
--                    (TypeDeclarator
--                       (FullType
--                          Nothing (TypeSpec Nothing (TypeSpecNoPrecision Float Nothing))))
--                    [ InitDecl "a" Nothing (Just (FloatConstant 1.0)) ])
--             , ExpressionStatement
--                 (Just (FunctionCall (FuncId "fun1") (Params [])))
--             , ExpressionStatement
--                 (Just (FunctionCall (FuncId "fun2") (Params [])))
--             , ExpressionStatement
--                 (Just
--                    (Equal (Variable "x") (FunctionCall (FuncId "fun3") (Params []))))
--             ])
--      ])

runBuilder a = (shader_header <> ufsGLSL <> sdf_utils <> prettyShow glsl, u) where
    (u, s)    = runState a (mempty :: GLSLState)
    color     = s ^. stdUniforms . colorx
    ast       = unit [ func' "main" [ param void ] $ compound [ val vec2 "local"  $ "luv" * "boxSize"
                                                              , val vec2 "ulocal" $ "local" * "dpr"
                                                              , val vec2 "p"      $ "ulocal" - ("boxSize" / 2.0) + "boxOffset"
                                                              , color .= "vec4" [0.1,0.1,0.1,0.0]
                                                              ] <> (s ^. glslAST)
                     ]
    glsl      = ast
    ufs       = s ^. uniforms
    ufsDecls  = fmap getExt ufs
    ufsGLSL   = prettyShow $ unit ufsDecls

    getExt (UniformDecl _ ext) = ext

--prettyShowUnit (TranslationUnit u) = prettyShow u


-- Instances

instance GLSLBuilder t m u => GLSLBuilder (Bounded b t) m u where
    toGLSL (Bounded _ a) = toGLSL a

