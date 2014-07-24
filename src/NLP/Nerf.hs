{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}


-- | Main module of the Nerf tool.


module NLP.Nerf
(
-- * Mode
  Nerf (..)
, saveModel
, loadModel

-- * NER
, ner
, ner'

-- * Training
, train
, train'

-- * OX
, tryOx
, tryOx'
, module NLP.Nerf.Types
) where


import           Control.Applicative ((<$>), (<*>))
import           Control.Monad (when)
import           Data.Binary (Binary, put, get)
import qualified Data.Binary as Binary
import           Data.Foldable (foldMap)
import           Data.List (intercalate)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Lazy.IO as L
import qualified Data.ByteString.Lazy as BL
import qualified Codec.Compression.GZip as GZip

import           Text.Named.Enamex (parseEnamex)
import qualified Data.Named.Tree as N
import qualified Data.Named.IOB as IOB

import qualified Data.Tagset.Positional as P

import           Numeric.SGD (SgdArgs)
import qualified Data.CRF.Chain1 as CRF

import           NLP.Nerf.Types
import           NLP.Nerf.Tokenize (tokenize, sync)
import           NLP.Nerf.Schema (SchemaConf, Schema, fromConf, schematize)
import qualified NLP.Nerf.XCES2 as XCES


---------------------
-- Model
---------------------


modelVersion :: String
modelVersion = "0.6"


-- | A Nerf consists of the observation schema configuration and the CRF model.
data Nerf = Nerf
    { schemaConf    :: SchemaConf
    , crf           :: CRF.CRF Ob Lb
    , tagset        :: P.Tagset }

instance Binary Nerf where
    put Nerf{..} = do
        put modelVersion
        put schemaConf
        put crf 
        put tagset
    get = do
        comp <- get     
        when (comp /= modelVersion) $ error $
            "Incompatible model version: " ++ comp ++
            ", expected: " ++ modelVersion
        Nerf <$> get <*> get <*> get


-- | Save model in a file.  Data is compressed using the gzip format.
saveModel :: FilePath -> Nerf -> IO ()
saveModel path = BL.writeFile path . GZip.compress . Binary.encode


-- | Load model from a file.
loadModel :: FilePath -> IO Nerf
loadModel path = do
    x <- Binary.decode . GZip.decompress <$> BL.readFile path
    x `seq` return x


---------------------
-- Train
---------------------


-- | Train Nerf on the input data using the SGD method.
train
    :: P.Tagset             -- ^ Tagset definition
    -> SgdArgs              -- ^ Args for SGD
    -> SchemaConf           -- ^ Observation schema configuration
    -> FilePath             -- ^ Train data (ENAMEX)
    -> Maybe FilePath       -- ^ Maybe eval data (ENAMEX)
    -> IO Nerf              -- ^ Nerf with resulting codec and model
train tagset sgdArgs cfg trainPath evalPathM = do
    let schema = fromConf cfg
        readTrain = readFlat schema trainPath
        readEval  = case evalPathM of 
            Just evalPath -> readFlat schema evalPath
            Nothing -> return []
    _crf <- CRF.train sgdArgs True CRF.presentFeats [] readTrain readEval
    return $ Nerf cfg _crf tagset


---------------------
-- NER
---------------------


-- | Perform named entity recognition (NER) using the Nerf model.
ner :: Nerf -> String -> N.NeForest NE T.Text
ner nerf sent =
    -- TODO: we could try to recover `nps` attributes.
    let mkWord x = Word {orth = x, nps = False, msd = Nothing}
        ws = map T.pack . tokenize $ sent
        schema = fromConf (schemaConf nerf)
        xs = CRF.tag (crf nerf) (schematize schema $ map mkWord ws)
    in  IOB.decodeForest [IOB.IOB w x | (w, x) <- zip ws xs]


---------------------
-- Enamex
---------------------


-- | Read data from enamex file and retokenize (so that internal
-- tokenization is used).
readDeep :: FilePath -> IO [N.NeForest NE Word]
readDeep path
    = map (mkForest . reTokenize)
    . parseEnamex <$> L.readFile path
  where
    mkForest = N.mapForest $ N.onEither mkNE mkWord
    mkNE x = M.singleton "" x
    -- TODO: we could try to recover `nps` attributes.
    mkWord x = Word {orth = x, nps = False, msd = Nothing}


-- | Like `readDeep` but also converts to the CRF representation.
readFlat :: Schema a -> FilePath -> IO [CRF.SentL Ob Lb]
readFlat schema path = map (flatten schema) <$> readDeep path


---------------------
-- CRF
---------------------


-- | Flatten the forest into a CRF representation.
flatten :: Schema a -> N.NeForest NE Word -> CRF.SentL Ob Lb
flatten schema forest =
    [ CRF.annotate x y
    | (x, y) <- zip xs ys ]
  where
    iob = IOB.encodeForest forest
    xs = schematize schema (map IOB.word iob)
    ys = map IOB.label iob


---------------------
-- Re-tokenization
---------------------


-- | Tokenize sentence with the Nerf tokenizer.
reTokenize :: N.NeForest a T.Text -> N.NeForest a T.Text
reTokenize ft = 
    sync ft ((doTok . leaves) ft)
  where 
    doTok  = map T.pack . tokenize . intercalate " "  . map T.unpack
    leaves = concatMap $ foldMap (either (const []) (:[]))


---------------------
-- Try OX
---------------------


-- | Show results of observation extraction on the input ENAMEX file.
tryOx :: SchemaConf -> FilePath -> IO ()
tryOx cfg path = do
    input <- readFlat (fromConf cfg) path
    mapM_ drawSent input


-- | Show results of observation extraction on the input XCES file.
tryOx' :: P.Tagset -> SchemaConf -> FilePath -> IO ()
tryOx' tagset cfg path = do
    input <- readFlatXCES tagset (fromConf cfg) path
    mapM_ drawSent input


drawSent :: CRF.SentL Ob Lb -> IO ()
drawSent sent = do
    let unDist (x, y) = (x, CRF.unDist y)
    mapM_ (print . unDist) sent
    putStrLn "" 


------------------------------------------------------------
-- New version (preliminary implementation)
------------------------------------------------------------


-- | Perform NER on a morphosyntactically disambiguated sentence.
-- No re-tokenizetion is performed.
ner' :: (w -> Word) -> Nerf -> [w]  -> N.NeForest NE w
ner' f nerf ws =
    let schema = fromConf (schemaConf nerf)
        xs = CRF.tag (crf nerf) (schematize schema $ map f ws)
    in  IOB.decodeForest [IOB.IOB w x | (w, x) <- zip ws xs]


-- | Train Nerf on a morphosyntactically annotated (and disambiguated) data.
train'
    :: P.Tagset             -- ^ Tagset definition
    -> SgdArgs              -- ^ Args for SGD
    -> SchemaConf           -- ^ Observation schema configuration
    -> FilePath             -- ^ Train data (XCES)
    -> Maybe FilePath       -- ^ Maybe eval data (XCES)
    -> IO Nerf              -- ^ The resulting Nerf model
train' tagset sgdArgs cfg trainPath evalPathM = do
    let schema = fromConf cfg
        readTrain = readFlatXCES tagset schema trainPath
--         readEvalM = evalPathM >>= \evalPath ->
--             Just ([], readFlatXCES schema evalPath)
        readEval  = case evalPathM of 
            Just evalPath -> readFlatXCES tagset schema evalPath
            Nothing -> return []
    -- mapM (mapM print) . XCES.parseXCES =<< L.readFile trainPath
    -- mapM (mapM print) =<< readDeepXCES tagset trainPath
    _crf <- CRF.train sgdArgs True CRF.presentFeats [] readTrain readEval
    return $ Nerf cfg _crf tagset


-- | Read data from the XCES.
--
-- TODO: specify `ns`s.
readDeepXCES :: P.Tagset -> FilePath -> IO [[N.NeForest NE Word]]
readDeepXCES tagset = 
    let prep = (map.map) (XCES.fromXCES tagset) . XCES.parseXCES
    in  fmap prep . L.readFile


-- | Like `readDeep` but also converts to the CRF representation.
readFlatXCES :: P.Tagset -> Schema a -> FilePath -> IO [CRF.SentL Ob Lb]
readFlatXCES tagset schema path
    = map (flatten schema) . concat
    <$> readDeepXCES tagset path
