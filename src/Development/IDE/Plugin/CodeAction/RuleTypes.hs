{-# LANGUAGE TypeFamilies #-}
module Development.IDE.Plugin.CodeAction.RuleTypes
    (PackageExports(..), ExportsMap
    ,IdentInfo(..)
    ) where

import Development.IDE.GHC.Util
import Development.IDE.Types.Exports
import Development.Shake.Classes
import Development.Shake (RuleResult)
import GHC.Generics (Generic)

-- Rule type for caching Package Exports
type instance RuleResult PackageExports = ExportsMap

newtype PackageExports = PackageExports HscEnvEq
    deriving (Eq, Show, Typeable, Generic)

instance Hashable PackageExports
instance NFData   PackageExports
instance Binary   PackageExports
