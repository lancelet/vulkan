{-# language CPP #-}
module Vulkan.Extensions.VK_KHR_surface_protected_capabilities  ( SurfaceProtectedCapabilitiesKHR(..)
                                                                , KHR_SURFACE_PROTECTED_CAPABILITIES_SPEC_VERSION
                                                                , pattern KHR_SURFACE_PROTECTED_CAPABILITIES_SPEC_VERSION
                                                                , KHR_SURFACE_PROTECTED_CAPABILITIES_EXTENSION_NAME
                                                                , pattern KHR_SURFACE_PROTECTED_CAPABILITIES_EXTENSION_NAME
                                                                ) where

import Foreign.Marshal.Alloc (allocaBytesAligned)
import Foreign.Ptr (nullPtr)
import Foreign.Ptr (plusPtr)
import Data.String (IsString)
import Data.Typeable (Typeable)
import Foreign.Storable (Storable)
import Foreign.Storable (Storable(peek))
import Foreign.Storable (Storable(poke))
import qualified Foreign.Storable (Storable(..))
import GHC.Generics (Generic)
import Foreign.Ptr (Ptr)
import Data.Kind (Type)
import Vulkan.Core10.BaseType (bool32ToBool)
import Vulkan.Core10.BaseType (boolToBool32)
import Vulkan.Core10.BaseType (Bool32)
import Vulkan.CStruct (FromCStruct)
import Vulkan.CStruct (FromCStruct(..))
import Vulkan.Core10.Enums.StructureType (StructureType)
import Vulkan.CStruct (ToCStruct)
import Vulkan.CStruct (ToCStruct(..))
import Vulkan.Zero (Zero(..))
import Vulkan.Core10.Enums.StructureType (StructureType(STRUCTURE_TYPE_SURFACE_PROTECTED_CAPABILITIES_KHR))
-- | VkSurfaceProtectedCapabilitiesKHR - Structure describing capability of a
-- surface to be protected
--
-- == Valid Usage (Implicit)
--
-- = See Also
--
-- 'Vulkan.Core10.BaseType.Bool32',
-- 'Vulkan.Core10.Enums.StructureType.StructureType'
data SurfaceProtectedCapabilitiesKHR = SurfaceProtectedCapabilitiesKHR
  { -- | @supportsProtected@ specifies whether a protected swapchain created from
    -- 'Vulkan.Extensions.VK_KHR_get_surface_capabilities2.PhysicalDeviceSurfaceInfo2KHR'::@surface@
    -- for a particular windowing system /can/ be displayed on screen or not.
    -- If @supportsProtected@ is 'Vulkan.Core10.BaseType.TRUE', then creation
    -- of swapchains with the
    -- 'Vulkan.Extensions.VK_KHR_swapchain.SWAPCHAIN_CREATE_PROTECTED_BIT_KHR'
    -- flag set /must/ be supported for @surface@.
    supportsProtected :: Bool }
  deriving (Typeable, Eq)
#if defined(GENERIC_INSTANCES)
deriving instance Generic (SurfaceProtectedCapabilitiesKHR)
#endif
deriving instance Show SurfaceProtectedCapabilitiesKHR

instance ToCStruct SurfaceProtectedCapabilitiesKHR where
  withCStruct x f = allocaBytesAligned 24 8 $ \p -> pokeCStruct p x (f p)
  pokeCStruct p SurfaceProtectedCapabilitiesKHR{..} f = do
    poke ((p `plusPtr` 0 :: Ptr StructureType)) (STRUCTURE_TYPE_SURFACE_PROTECTED_CAPABILITIES_KHR)
    poke ((p `plusPtr` 8 :: Ptr (Ptr ()))) (nullPtr)
    poke ((p `plusPtr` 16 :: Ptr Bool32)) (boolToBool32 (supportsProtected))
    f
  cStructSize = 24
  cStructAlignment = 8
  pokeZeroCStruct p f = do
    poke ((p `plusPtr` 0 :: Ptr StructureType)) (STRUCTURE_TYPE_SURFACE_PROTECTED_CAPABILITIES_KHR)
    poke ((p `plusPtr` 8 :: Ptr (Ptr ()))) (nullPtr)
    poke ((p `plusPtr` 16 :: Ptr Bool32)) (boolToBool32 (zero))
    f

instance FromCStruct SurfaceProtectedCapabilitiesKHR where
  peekCStruct p = do
    supportsProtected <- peek @Bool32 ((p `plusPtr` 16 :: Ptr Bool32))
    pure $ SurfaceProtectedCapabilitiesKHR
             (bool32ToBool supportsProtected)

instance Storable SurfaceProtectedCapabilitiesKHR where
  sizeOf ~_ = 24
  alignment ~_ = 8
  peek = peekCStruct
  poke ptr poked = pokeCStruct ptr poked (pure ())

instance Zero SurfaceProtectedCapabilitiesKHR where
  zero = SurfaceProtectedCapabilitiesKHR
           zero


type KHR_SURFACE_PROTECTED_CAPABILITIES_SPEC_VERSION = 1

-- No documentation found for TopLevel "VK_KHR_SURFACE_PROTECTED_CAPABILITIES_SPEC_VERSION"
pattern KHR_SURFACE_PROTECTED_CAPABILITIES_SPEC_VERSION :: forall a . Integral a => a
pattern KHR_SURFACE_PROTECTED_CAPABILITIES_SPEC_VERSION = 1


type KHR_SURFACE_PROTECTED_CAPABILITIES_EXTENSION_NAME = "VK_KHR_surface_protected_capabilities"

-- No documentation found for TopLevel "VK_KHR_SURFACE_PROTECTED_CAPABILITIES_EXTENSION_NAME"
pattern KHR_SURFACE_PROTECTED_CAPABILITIES_EXTENSION_NAME :: forall a . (Eq a, IsString a) => a
pattern KHR_SURFACE_PROTECTED_CAPABILITIES_EXTENSION_NAME = "VK_KHR_surface_protected_capabilities"

