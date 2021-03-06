{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Parsing the Gazetteer for Polish Named Entities (used formerly within
-- the SProUT platform) in the LMF format.

module NLP.Nerf.Dict.PNEG
( parsePNEG
, readPNEG
) where

import Text.XML.PolySoup
import qualified Data.Text as T
import qualified Data.Text.Lazy as L
import qualified Data.Text.Lazy.IO as L

import NLP.Nerf.Dict.Base

lmfP :: XmlParser L.Text [Entry]
lmfP = true ##> lexEntryP

lexEntryP :: XmlParser L.Text [Entry]
lexEntryP = tag "LexicalEntry" `joinR` do
    many_ $ cut $ tag "feat"
    _words <- many wordP
    sense  <- senseP
    return [Entry x sense | x <- _words]

wordP :: XmlParser L.Text Form
wordP = head <$> (tag "Lemma" <|> tag "WordForm" /> featP "writtenForm")

senseP :: XmlParser L.Text NeType
senseP = head <$> (tag "Sense" //> featP "externalReference" <|> featP "label")

featP :: L.Text -> XmlParser L.Text T.Text
featP x = L.toStrict <$> cut (tag "feat" *> hasAttr "att" x *> getAttr "val")

-- | Parse the dictionary to the list of entries.
parsePNEG :: L.Text -> [Entry]
parsePNEG = parseXml lmfP

-- | Read the dictionary from the file.
readPNEG :: FilePath -> IO [Entry]
readPNEG = fmap parsePNEG . L.readFile
