{-# LANGUAGE OverloadedLists #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module Main where

import           Control.Exception
import           Control.Monad.Trans.Maybe
import           Control.Monad
import           Control.Monad.Extra
import           Data.Ord
import           Control.Monad.IO.Class
import           Data.Bits
import           Data.Traversable
import           Foreign.Ptr                    ( castPtr )
import           Data.List                      ( nub )
import qualified Data.ByteString               as BS
import           Data.Word
import           Say
import           System.Exit
import           Data.String                    ( IsString )
import           Data.Text               hiding ( maximum )
import           Control.Monad.Managed
import qualified Data.Vector                   as V
import           Graphics.Vulkan.Core10
import           Graphics.Vulkan.Core11
import           Graphics.Vulkan.Extensions.VK_KHR_surface
import           Graphics.Vulkan.Extensions.VK_KHR_swapchain
import           Graphics.Vulkan.Extensions.VK_EXT_debug_utils
import           Graphics.Vulkan.Zero
import           Graphics.Vulkan.CStruct.Extends
import           Graphics.Vulkan.Version
import qualified SDL
import qualified SDL.Video.Vulkan              as SDL
import           Control.Arrow                  ( (&&&) )

-- pattern (::&) :: Extensible a => a es -> Chain es -> a es
-- pattern a ::& es <- (id &&& getNext -> (a, es))
--   where a ::& es = setNext a es

-- pattern (:&) :: e -> Chain es -> Chain (e:es)
-- pattern e :& es = (e, es)

main :: IO ()
main = runManaged $ do
  managed_ withSDL

  VulkanWindow {..} <- withVulkanWindow appName windowWidth windowHeight
  renderPass        <- Main.createRenderPass vwDevice vwFormat
  graphicsPipeline  <- createGraphicsPipeline vwDevice
                                              renderPass
                                              vwExtent
                                              vwFormat
  framebuffers   <- createFramebuffers vwDevice vwImageViews renderPass vwExtent
  commandBuffers <- createCommandBuffers vwDevice
                                         renderPass
                                         graphicsPipeline
                                         vwGraphicsQueueFamilyIndex
                                         framebuffers
                                         vwExtent
  (imageAvailableSemaphore, renderFinishedSemaphore) <- createSemaphores
    vwDevice
  SDL.showWindow vwSdlWindow
  liftIO . mainLoop $ drawFrame vwDevice
                                vwSwapchain
                                vwGraphicsQueue
                                vwPresentQueue
                                imageAvailableSemaphore
                                renderFinishedSemaphore
                                commandBuffers
  liftIO $ deviceWaitIdle vwDevice

mainLoop :: IO () -> IO ()
mainLoop draw = whileM $ do
  quit <- maybe False isQuitEvent <$> SDL.pollEvent
  if quit
    then pure False
    else do
      draw
      pure True

drawFrame
  :: Device
  -> SwapchainKHR
  -> Queue
  -> Queue
  -> Semaphore
  -> Semaphore
  -> V.Vector CommandBuffer
  -> IO ()
drawFrame dev swapchain graphicsQueue presentQueue imageAvailableSemaphore renderFinishedSemaphore commandBuffers
  = do
    (_, imageIndex) <- acquireNextImageKHR dev
                                           swapchain
                                           maxBound
                                           imageAvailableSemaphore
                                           zero
    let submitInfo = zero
          { waitSemaphores   = [imageAvailableSemaphore]
          , waitDstStageMask = [PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT]
          , commandBuffers   = [ commandBufferHandle
                                 $   commandBuffers
                                 V.! fromIntegral imageIndex
                               ]
          , signalSemaphores = [renderFinishedSemaphore]
          }
        presentInfo = zero { waitSemaphores = [renderFinishedSemaphore]
                           , swapchains     = [swapchain]
                           , imageIndices   = [imageIndex]
                           }
    queueSubmit graphicsQueue [submitInfo] zero
    _ <- queuePresentKHR presentQueue presentInfo
    pure ()

createSemaphores :: Device -> Managed (Semaphore, Semaphore)
createSemaphores dev = do
  imageAvailableSemaphore <- managed $ withSemaphore dev zero Nothing
  renderFinishedSemaphore <- managed $ withSemaphore dev zero Nothing
  pure (imageAvailableSemaphore, renderFinishedSemaphore)

createCommandBuffers
  :: Device
  -> RenderPass
  -> Pipeline
  -> Word32
  -> V.Vector Framebuffer
  -> Extent2D
  -> Managed (V.Vector CommandBuffer)
createCommandBuffers dev renderPass graphicsPipeline graphicsQueueFamilyIndex framebuffers swapchainExtent
  = do
    let commandPoolCreateInfo :: CommandPoolCreateInfo
        commandPoolCreateInfo =
          zero { queueFamilyIndex = graphicsQueueFamilyIndex }
    commandPool <- managed $ withCommandPool dev commandPoolCreateInfo Nothing
    let commandBufferAllocateInfo :: CommandBufferAllocateInfo
        commandBufferAllocateInfo = zero
          { commandPool        = commandPool
          , level              = COMMAND_BUFFER_LEVEL_PRIMARY
          , commandBufferCount = fromIntegral $ V.length framebuffers
          }
    buffers <- managed $ withCommandBuffers dev commandBufferAllocateInfo
    _ <- liftIO $ for (V.zip framebuffers buffers) $ \(framebuffer, buffer) ->
      useCommandBuffer
          buffer
          zero { flags = COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT }
        $ do
            let renderPassBeginInfo = zero
                  { renderPass  = renderPass
                  , framebuffer = framebuffer
                  , renderArea  = Rect2D { offset = zero
                                         , extent = swapchainExtent
                                         }
                  , clearValues = [Color (Float32 (0.1, 0.1, 0.1, 0))]
                  }
            cmdBeginRenderPass buffer
                               renderPassBeginInfo
                               SUBPASS_CONTENTS_INLINE
            cmdBindPipeline buffer PIPELINE_BIND_POINT_GRAPHICS graphicsPipeline
            cmdDraw buffer 3 1 0 0
            cmdEndRenderPass buffer
    pure buffers

createShaders
  :: Device -> Managed (V.Vector (SomeStruct PipelineShaderStageCreateInfo))
createShaders dev = do
  frag       <- liftIO $ BS.readFile "examples/sdl-triangle/frag.spv"
  vert       <- liftIO $ BS.readFile "examples/sdl-triangle/vert.spv"
  fragModule <- managed $ withShaderModule dev zero { code = frag } Nothing
  vertModule <- managed $ withShaderModule dev zero { code = vert } Nothing
  let vertShaderStageCreateInfo = zero { stage   = SHADER_STAGE_VERTEX_BIT
                                       , module' = vertModule
                                       , name    = "main"
                                       }
      fragShaderStageCreateInfo = zero { stage   = SHADER_STAGE_FRAGMENT_BIT
                                       , module' = fragModule
                                       , name    = "main"
                                       }
  pure
    [SomeStruct vertShaderStageCreateInfo, SomeStruct fragShaderStageCreateInfo]

createRenderPass :: Device -> Format -> Managed RenderPass
createRenderPass dev swapchainImageFormat = do
  let
    attachmentDescription :: AttachmentDescription
    attachmentDescription = zero
      { format         = swapchainImageFormat
      , samples        = SAMPLE_COUNT_1_BIT
      , loadOp         = ATTACHMENT_LOAD_OP_CLEAR
      , storeOp        = ATTACHMENT_STORE_OP_STORE
      , stencilLoadOp  = ATTACHMENT_LOAD_OP_DONT_CARE
      , stencilStoreOp = ATTACHMENT_STORE_OP_DONT_CARE
      , initialLayout  = IMAGE_LAYOUT_UNDEFINED
      , finalLayout    = IMAGE_LAYOUT_PRESENT_SRC_KHR
      }
    subpass :: SubpassDescription
    subpass = zero
      { pipelineBindPoint = PIPELINE_BIND_POINT_GRAPHICS
      , colorAttachments  =
        [ zero { attachment = 0
               , layout     = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
               }
        ]
      }
    subpassDependency :: SubpassDependency
    subpassDependency = zero
      { srcSubpass    = SUBPASS_EXTERNAL
      , dstSubpass    = 0
      , srcStageMask  = PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
      , srcAccessMask = zero
      , dstStageMask  = PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
      , dstAccessMask = ACCESS_COLOR_ATTACHMENT_READ_BIT
                          .|. ACCESS_COLOR_ATTACHMENT_WRITE_BIT
      }
  managed $ withRenderPass
    dev
    zero { attachments  = [attachmentDescription]
         , subpasses    = [subpass]
         , dependencies = [subpassDependency]
         }
    Nothing

createGraphicsPipeline
  :: Device -> RenderPass -> Extent2D -> Format -> Managed Pipeline
createGraphicsPipeline dev renderPass swapchainExtent swapchainImageFormat = do
  shaderStages   <- createShaders dev
  pipelineLayout <- managed $ withPipelineLayout dev zero Nothing
  let
    pipelineCreateInfo :: GraphicsPipelineCreateInfo '[]
    pipelineCreateInfo = zero
      { stages             = shaderStages
      , vertexInputState   = Just zero
      , inputAssemblyState = Just zero
                               { topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
                               , primitiveRestartEnable = False
                               }
      , viewportState      = Just . SomeStruct $ zero
        { viewports = Right
          [ Viewport
              { x        = 0
              , y        = 0
              , width    = realToFrac (width (swapchainExtent :: Extent2D))
              , height   = realToFrac (height (swapchainExtent :: Extent2D))
              , minDepth = 0
              , maxDepth = 1
              }
          ]
        , scissors  = Right
          [Rect2D { offset = Offset2D 0 0, extent = swapchainExtent }]
        }
      , rasterizationState = SomeStruct $ zero
                               { depthClampEnable        = False
                               , rasterizerDiscardEnable = False
                               , lineWidth               = 1
                               , polygonMode             = POLYGON_MODE_FILL
                               , cullMode                = CULL_MODE_NONE
                               , frontFace               = FRONT_FACE_CLOCKWISE
                               , depthBiasEnable         = False
                               }
      , multisampleState   = Just . SomeStruct $ zero
                               { sampleShadingEnable  = False
                               , rasterizationSamples = SAMPLE_COUNT_1_BIT
                               , minSampleShading     = 1
                               , sampleMask           = [maxBound]
                               }
      , depthStencilState  = Nothing
      , colorBlendState    = Just . SomeStruct $ zero
                               { logicOpEnable = False
                               , attachments   = [ zero
                                                     { colorWriteMask =
                                                       COLOR_COMPONENT_R_BIT
                                                       .|. COLOR_COMPONENT_G_BIT
                                                       .|. COLOR_COMPONENT_B_BIT
                                                       .|. COLOR_COMPONENT_A_BIT
                                                     , blendEnable    = False
                                                     }
                                                 ]
                               }
      , dynamicState       = Nothing
      , layout             = pipelineLayout
      , renderPass         = renderPass
      , subpass            = 0
      , basePipelineHandle = zero
      }
  fmap V.head $ managed $ withGraphicsPipelines dev
                                                zero
                                                [pipelineCreateInfo]
                                                Nothing

createFramebuffers
  :: Device
  -> V.Vector ImageView
  -> RenderPass
  -> Extent2D
  -> Managed (V.Vector Framebuffer)
createFramebuffers dev imageViews renderPass swapchainExtent =
  for imageViews $ \imageView -> do
    let framebufferCreateInfo :: FramebufferCreateInfo '[]
        framebufferCreateInfo = zero
          { renderPass  = renderPass
          , attachments = [imageView]
          , width       = width (swapchainExtent :: Extent2D)
          , height      = height (swapchainExtent :: Extent2D)
          , layers      = 1
          }
    managed $ withFramebuffer dev framebufferCreateInfo Nothing

data VulkanWindow = VulkanWindow
  { vwSdlWindow                :: SDL.Window
  , vwDevice                   :: Device
  , vwSurface                  :: SurfaceKHR
  , vwSwapchain                :: SwapchainKHR
  , vwExtent                   :: Extent2D
  , vwFormat                   :: Format
  , vwImageViews               :: V.Vector ImageView
  , vwGraphicsQueue            :: Queue
  , vwGraphicsQueueFamilyIndex :: Word32
  , vwPresentQueue             :: Queue
  }

withVulkanWindow :: Text -> Int -> Int -> Managed VulkanWindow
withVulkanWindow appName width height = do
  -- sayShow =<< SDL.vkLoadLibrary
  --   (Just
  --     "/nix/store/5q53qn1wbg3bpipjwniz565wc7asx9p-swiftshader-2020-03-31/lib/libvulkan.so.1"
  --   )
  -- sayShow "hello"
  -- sayShow =<< Raw.vkLoadLibrary (Ptr "/dev/nul"#)
  window             <- managed $ withWindow appName width height
  instanceCreateInfo <- liftIO $ windowInstanceCreateInfo window
  inst               <- managed $ withInstance instanceCreateInfo Nothing
  _                  <- managed
    $ withDebugUtilsMessengerEXT inst debugUtilsMessengerCreateInfo Nothing
  liftIO $ submitDebugUtilsMessageEXT
    inst
    DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
    DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
    zero { message = "Debug Message Test" }
  surface <- managed $ withSDLWindowSurface inst window
  (dev, graphicsQueue, graphicsQueueFamilyIndex, presentQueue, swapchainFormat, swapchainExtent, swapchain) <-
    createGraphicalDevice inst surface
  (_, images) <- liftIO $ getSwapchainImagesKHR dev swapchain
  let imageViewCreateInfo i = zero
        { image            = i
        , viewType         = IMAGE_VIEW_TYPE_2D
        , format           = swapchainFormat
        , components       = zero { r = COMPONENT_SWIZZLE_IDENTITY
                                  , g = COMPONENT_SWIZZLE_IDENTITY
                                  , b = COMPONENT_SWIZZLE_IDENTITY
                                  , a = COMPONENT_SWIZZLE_IDENTITY
                                  }
        , subresourceRange = zero { aspectMask     = IMAGE_ASPECT_COLOR_BIT
                                  , baseMipLevel   = 0
                                  , levelCount     = 1
                                  , baseArrayLayer = 0
                                  , layerCount     = 1
                                  }
        }
  imageViews <- for images
    $ \i -> managed $ withImageView dev (imageViewCreateInfo i) Nothing
  pure $ VulkanWindow window
                      dev
                      surface
                      swapchain
                      swapchainExtent
                      swapchainFormat
                      imageViews
                      graphicsQueue
                      graphicsQueueFamilyIndex
                      presentQueue

appName :: IsString a => a
appName = "vulkan triangle example"

windowWidth, windowHeight :: Int
windowWidth = 1920
windowHeight = 1080

-- | InstanceCreateInfo for an SDL window
windowInstanceCreateInfo
  :: SDL.Window -> IO (InstanceCreateInfo '[DebugUtilsMessengerCreateInfoEXT])
windowInstanceCreateInfo window = do
  windowExtensions <- traverse BS.packCString
    =<< SDL.vkGetInstanceExtensions window
  let requiredLayers = ["VK_LAYER_LUNARG_standard_validation"]
      requiredExtensions =
        V.fromList $ EXT_DEBUG_UTILS_EXTENSION_NAME : windowExtensions
  pure zero
    { next                  = (debugUtilsMessengerCreateInfo, ())
    , applicationInfo       = Just zero { applicationName = Just appName
                                        , apiVersion      = MAKE_VERSION 1 1 0
                                        }
    , enabledLayerNames     = requiredLayers
    , enabledExtensionNames = requiredExtensions
    }

createGraphicalDevice
  :: Instance
  -> SurfaceKHR
  -> Managed
       (Device, Queue, Word32, Queue, Format, Extent2D, SwapchainKHR)
createGraphicalDevice inst surface = do
  let requiredDeviceExtensions = [KHR_SWAPCHAIN_EXTENSION_NAME]
  (physicalDevice, graphicsQueueFamilyIndex, presentQueueFamilyIndex, surfaceFormat, presentMode, surfaceCaps) <-
    liftIO $ pickGraphicalPhysicalDevice
      inst
      surface
      requiredDeviceExtensions
      (SurfaceFormatKHR FORMAT_B8G8R8_UNORM COLOR_SPACE_SRGB_NONLINEAR_KHR)
  let
    deviceCreateInfo :: DeviceCreateInfo '[]
    deviceCreateInfo = zero
      { queueCreateInfos      = V.fromList
        [ SomeStruct $ zero { queueFamilyIndex = i
                            , queuePriorities = [1]
                            , flags = DEVICE_QUEUE_CREATE_PROTECTED_BIT
                            }
        | i <- nub [graphicsQueueFamilyIndex, presentQueueFamilyIndex]
        ]
      , enabledExtensionNames = requiredDeviceExtensions
      }
  dev           <- managed $ withDevice physicalDevice deviceCreateInfo Nothing
  graphicsQueue <- liftIO $ getDeviceQueue2
    dev
    zero { queueFamilyIndex = graphicsQueueFamilyIndex
         , flags            = DEVICE_QUEUE_CREATE_PROTECTED_BIT
         }
  presentQueue <- liftIO $ getDeviceQueue2
    dev
    zero { queueFamilyIndex = presentQueueFamilyIndex
         , flags            = DEVICE_QUEUE_CREATE_PROTECTED_BIT
         }
  let
    swapchainCreateInfo :: SwapchainCreateInfoKHR '[]
    swapchainCreateInfo =
      let (sharingMode, queueFamilyIndices) = if graphicsQueue == presentQueue
            then (SHARING_MODE_EXCLUSIVE, [])
            else
              ( SHARING_MODE_CONCURRENT
              , [graphicsQueueFamilyIndex, presentQueueFamilyIndex]
              )
      in
        zero
          { surface            = surface
          , minImageCount      = minImageCount
                                     (surfaceCaps :: SurfaceCapabilitiesKHR)
                                   + 1
          , imageFormat = (format :: SurfaceFormatKHR -> Format) surfaceFormat
          , imageColorSpace    = colorSpace surfaceFormat
          , imageExtent        = case
                                   currentExtent
                                     (surfaceCaps :: SurfaceCapabilitiesKHR)
                                 of
                                   Extent2D w h | w == maxBound, h == maxBound ->
                                     Extent2D (fromIntegral windowWidth)
                                              (fromIntegral windowHeight)
                                   e -> e
          , imageArrayLayers   = 1
          , imageUsage         = IMAGE_USAGE_COLOR_ATTACHMENT_BIT
          , imageSharingMode   = sharingMode
          , queueFamilyIndices = queueFamilyIndices
          , preTransform       = currentTransform
                                   (surfaceCaps :: SurfaceCapabilitiesKHR)
          , compositeAlpha     = COMPOSITE_ALPHA_OPAQUE_BIT_KHR
          , presentMode        = presentMode
          , clipped            = True
          }
  swapchain <- managed $ withSwapchainKHR dev swapchainCreateInfo Nothing
  pure
    ( dev
    , graphicsQueue
    , graphicsQueueFamilyIndex
    , presentQueue
    , format (surfaceFormat :: SurfaceFormatKHR)
    , imageExtent (swapchainCreateInfo :: SwapchainCreateInfoKHR '[])
    , swapchain
    )

-- | Find the device which has the most memory and a graphics queue family index
pickGraphicalPhysicalDevice
  :: Instance
  -> SurfaceKHR
  -> V.Vector BS.ByteString
  -> SurfaceFormatKHR
  -> IO
       ( PhysicalDevice
       , Word32
       , Word32
       , SurfaceFormatKHR
       , PresentModeKHR
       , SurfaceCapabilitiesKHR
       )
pickGraphicalPhysicalDevice inst surface requiredExtensions desiredFormat = do
  (_, devs)    <- enumeratePhysicalDevices inst
  -- All devices with support for all the graphical features we want
  graphicsDevs <- fmap (V.mapMaybe id) . for devs $ \dev -> runMaybeT $ do
    graphicsQueue <- MaybeT $ headMay <$> getGraphicsQueueIndices dev
    presentQueue  <- MaybeT $ headMay <$> getPresentQueueIndices dev
    guard =<< liftIO (deviceHasSwapChain dev)
    bestFormat  <- getFormat dev
    presentMode <- getPresentMode dev
    surfaceCaps <- liftIO $ getPhysicalDeviceSurfaceCapabilitiesKHR dev surface
    score       <- liftIO $ deviceScore dev
    pure
      ( score
      , (dev, graphicsQueue, presentQueue, bestFormat, presentMode, surfaceCaps)
      )
  if V.null graphicsDevs
    then do
      sayErr "No suitable devices found"
      exitFailure
    else pure . snd . V.maximumBy (comparing fst) $ graphicsDevs

 where
  headMay = \case
    [] -> Nothing
    xs -> Just (V.unsafeHead xs)

  deviceScore :: PhysicalDevice -> IO Word64
  deviceScore dev = do
    -- may be useful later...
    -- print =<< getPhysicalDeviceProperties2 @'[PhysicalDevicePushDescriptorPropertiesKHR] dev
    print =<< getPhysicalDeviceProperties2 @'[] dev
    print =<< getPhysicalDeviceFeatures dev
    heaps <- memoryHeaps <$> getPhysicalDeviceMemoryProperties dev
    let totalSize = sum $ (size :: MemoryHeap -> DeviceSize) <$> heaps
    pure totalSize

  deviceHasSwapChain :: PhysicalDevice -> IO Bool
  deviceHasSwapChain dev = do
    (_, extensions) <- enumerateDeviceExtensionProperties dev Nothing
    pure $ V.any ((KHR_SWAPCHAIN_EXTENSION_NAME ==) . extensionName) extensions

  getGraphicsQueueIndices :: PhysicalDevice -> IO (V.Vector Word32)
  getGraphicsQueueIndices dev = do
    queueFamilyProperties <- getPhysicalDeviceQueueFamilyProperties dev
    let isGraphicsQueue q =
          (QUEUE_GRAPHICS_BIT .&&. queueFlags q) && (queueCount q > 0)
        graphicsQueueIndices = fromIntegral . fst <$> V.filter
          (isGraphicsQueue . snd)
          (V.indexed queueFamilyProperties)
    pure graphicsQueueIndices

  getPresentQueueIndices :: PhysicalDevice -> IO (V.Vector Word32)
  getPresentQueueIndices dev = do
    -- TODO: implement getNum...
    numQueues <- V.length <$> getPhysicalDeviceQueueFamilyProperties2 @'[] dev
    let queueIndices = V.generate (fromIntegral numQueues) fromIntegral
    V.filterM
      (\i -> (True ==) <$> getPhysicalDeviceSurfaceSupportKHR dev i surface)
      queueIndices

  getFormat :: PhysicalDevice -> MaybeT IO SurfaceFormatKHR
  getFormat dev = do
    (_, formats) <- liftIO $ getPhysicalDeviceSurfaceFormatsKHR dev surface
    pure $ case formats of
      [] -> desiredFormat
      [SurfaceFormatKHR FORMAT_UNDEFINED _] -> desiredFormat
      _
        | V.any
          (\f ->
            format (f :: SurfaceFormatKHR)
              == format (desiredFormat :: SurfaceFormatKHR)
              && colorSpace (f :: SurfaceFormatKHR)
              == colorSpace (desiredFormat :: SurfaceFormatKHR)
          )
          formats
        -> desiredFormat
      _ -> V.head formats

  getPresentMode :: PhysicalDevice -> MaybeT IO PresentModeKHR
  getPresentMode dev = do
    (_, presentModes) <- liftIO
      $ getPhysicalDeviceSurfacePresentModesKHR dev surface
    let desiredPresentModes =
          [ PRESENT_MODE_MAILBOX_KHR
          , PRESENT_MODE_FIFO_KHR
          , PRESENT_MODE_IMMEDIATE_KHR
          ]
    MaybeT
      . pure
      . headMay
      . V.filter (`V.elem` presentModes)
      $ desiredPresentModes

----------------------------------------------------------------
-- Debugging
----------------------------------------------------------------

debugUtilsMessengerCreateInfo :: DebugUtilsMessengerCreateInfoEXT
debugUtilsMessengerCreateInfo = zero
  { messageSeverity = -- DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT
                      -- .|. DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT
                      -- .|.
                      DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
                        .|. DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
  , messageType     = DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
                      .|. DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
                      .|. DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
  , pfnUserCallback = debugCallbackPtr
  }

foreign import ccall unsafe "DebugCallback.c &debugCallback"
  debugCallbackPtr :: PFN_vkDebugUtilsMessengerCallbackEXT

----------------------------------------------------------------
-- SDL helpers
----------------------------------------------------------------

-- | Run something having initialized SDL
withSDL :: IO a -> IO a
withSDL =
  bracket_
      (SDL.initialize ([SDL.InitEvents, SDL.InitVideo] :: [SDL.InitFlag]))
      SDL.quit
    . bracket_ (SDL.vkLoadLibrary Nothing) SDL.vkUnloadLibrary

-- | Create an SDL window and use it
withWindow :: Text -> Int -> Int -> (SDL.Window -> IO a) -> IO a
withWindow title width height = bracket
  (SDL.createWindow
    title
    (SDL.defaultWindow
      { SDL.windowInitialSize     = SDL.V2 (fromIntegral width)
                                           (fromIntegral height)
      , SDL.windowGraphicsContext = SDL.VulkanContext
      }
    )
  )
  SDL.destroyWindow

isQuitEvent :: SDL.Event -> Bool
isQuitEvent = \case
  (SDL.Event _ SDL.QuitEvent) -> True
  SDL.Event _ (SDL.KeyboardEvent (SDL.KeyboardEventData _ SDL.Released False (SDL.Keysym _ code _)))
    | code == SDL.KeycodeQ || code == SDL.KeycodeEscape
    -> True
  _ -> False

-- | Get the Vulkan surface for an SDL window
getSDLWindowSurface :: Instance -> SDL.Window -> IO SurfaceKHR
getSDLWindowSurface inst window =
  SurfaceKHR <$> SDL.vkCreateSurface window (castPtr (instanceHandle inst))

withSDLWindowSurface :: Instance -> SDL.Window -> (SurfaceKHR -> IO a) -> IO a
withSDLWindowSurface inst window = bracket
  (getSDLWindowSurface inst window)
  (\o -> destroySurfaceKHR inst o Nothing)

----------------------------------------------------------------
-- Bit utils
----------------------------------------------------------------

(.&&.) :: Bits a => a -> a -> Bool
x .&&. y = (/= zeroBits) (x .&. y)
