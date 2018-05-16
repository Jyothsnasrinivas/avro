{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
module Data.Avro.Deriving.NormSchema
where

import           Control.Monad.State.Strict
import           Data.Avro.Schema
import qualified Data.List                  as L
import           Data.List.NonEmpty         (NonEmpty ((:|)))
import qualified Data.Map.Strict            as M
import           Data.Maybe                 (catMaybes, fromMaybe)
import           Data.Semigroup             ((<>))
import qualified Data.Set                   as S
import           Data.Text                  (Text)
import qualified Data.Text                  as T

-- | Extracts all the records from the schema (flattens the schema)
-- Named types get resolved when needed to include at least one "inlined"
-- schema in each record and to make each record self-contained.
-- Note: Namespaces are not really supported in this version. All the
-- namespaces (including inlined into full names) will be ignored
-- during names resolution.
extractDerivables :: Schema -> [Schema]
extractDerivables s = flip evalState state . normSchema . snd <$> rawRecs
  where
    rawRecs = getTypes s
    state = M.fromList rawRecs

getTypes :: Type -> [(TypeName, Type)]
getTypes rec = case rec of
  r@Record{name, fields} -> (name,r) : (fields >>= (getTypes . fldType))
  Array t                -> getTypes t
  Union (t1 :| ts) _     -> getTypes t1 <> concatMap getTypes ts
  Map t                  -> getTypes t
  e@Enum{name}           -> [(name, e)]
  f@Fixed{name}          -> [(name, f)]
  _                      -> []

-- Ensures normalisation: "extracted" record is self-contained and
-- all the named types are resolvable within the scope of the schema.
-- TODO: Improve story with namespaces
normSchema :: Schema -> State (M.Map TypeName Schema) Schema
normSchema r = case r of
  t@(NamedType tn) -> do
    let sn = shortName tn
    resolved <- get
    case M.lookup sn resolved of
      Just rs ->
        -- use the looked up schema (which might be a full record) and replace
        -- it in the state with NamedType for future resolves
        -- because only one full definition per schema is needed
        modify' (M.insert sn t) >> pure rs

        -- NamedType but no corresponding record?! Baaad!
      Nothing ->
        error $ "Unable to resolve schema: " <> show (typeName t)

  Array s   -> Array <$> normSchema s
  Map s     -> Map <$> normSchema s
  r@Record{name = tn}  -> do
    let sn = shortName tn
    modify' (M.insert sn r)
    flds <- mapM (\fld -> setType fld <$> normSchema (fldType fld)) (fields r)
    pure $ r { fields = flds }
  s         -> pure s
  where
    shortName tn = TN $ T.takeWhileEnd (/='.') (unTN tn)
    setType fld t = fld { fldType = t}
    fullName s = TN $ maybe (typeName s) (\n -> typeName s <> "." <> n) (namespace s)
