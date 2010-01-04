-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Layout.IndependentScreens
-- Copyright   :  (c) 2009 Daniel Wagner
-- License     :  BSD3
--
-- Maintainer  :  <daniel@wagner-home.com>
-- Stability   :  unstable
-- Portability :  unportable
--
-- Utility functions for simulating independent sets of workspaces on
-- each screen (like dwm's workspace model), using internal tags to
-- distinguish workspaces associated with each screen.
-----------------------------------------------------------------------------

module XMonad.Layout.IndependentScreens (
    -- * Usage
    -- $usage
    VirtualWorkspace, PhysicalWorkspace,
    workspaces',
    withScreens, onCurrentScreen,
    countScreens,
    marshallPP,
    marshall, unmarshall, unmarshallS, unmarshallW,
    marshallWindowSpace, unmarshallWindowSpace
) where

-- for the screen stuff
import Control.Arrow hiding ((|||))
import Control.Monad
import Data.List
import Graphics.X11.Xinerama
import XMonad
import XMonad.StackSet hiding (filter, workspaces)
import XMonad.Hooks.DynamicLog

-- $usage
-- You can use this module with the following in your @~\/.xmonad\/xmonad.hs@:
--
-- > import XMonad.Layout.IndependentScreens
--
-- You can define your workspaces by calling @withScreens@:
--
-- > myConfig = defaultConfig { workspaces = withScreens 2 ["web", "email", "irc"] }
--
-- This will create \"physical\" workspaces with distinct internal names for
-- each (screen, virtual workspace) pair.
--
-- Then edit any keybindings that use the list of workspaces or refer
-- to specific workspace names.  In the default configuration, only
-- the keybindings for changing workspace do this:
--
-- > [((m .|. modm, k), windows $ f i)
-- >     | (i, k) <- zip (XMonad.workspaces conf) [xK_1 .. xK_9]
-- >     , (f, m) <- [(W.greedyView, 0), (W.shift, shiftMask)]]
--
-- This should change to
--
-- > [((m .|. modm, k), windows $ onCurrentScreen f i)
-- >     | (i, k) <- zip (workspaces' conf) [xK_1 .. xK_9]
-- >     , (f, m) <- [(W.greedyView, 0), (W.shift, shiftMask)]]
--
-- In particular, the analogue of @XMonad.workspaces@ is
-- @workspaces'@, and you can use @onCurrentScreen@ to convert functions
-- of virtual workspaces to functions of physical workspaces, which work
-- by marshalling the virtual workspace name and the currently focused
-- screen into a physical workspace name.

type VirtualWorkspace  = WorkspaceId
type PhysicalWorkspace = WorkspaceId

marshall :: ScreenId -> VirtualWorkspace -> PhysicalWorkspace
marshall (S sc) vws = show sc ++ '_':vws

unmarshall  :: PhysicalWorkspace -> (ScreenId, VirtualWorkspace)
unmarshallS :: PhysicalWorkspace -> ScreenId
unmarshallW :: PhysicalWorkspace -> VirtualWorkspace

-- ^ You shouldn't need to use @marshall@ or the various @unmarshall@ functions
-- very much.  They simply convert between the physical and virtual worlds.
-- For example, you might want to use them as part of a status bar
-- configuration.  The function @unmarshallW@ would discard the screen
-- information from an otherwise unsightly workspace name.

unmarshall  = ((S . read) *** drop 1) . break (=='_')
unmarshallS = fst . unmarshall
unmarshallW = snd . unmarshall

workspaces' :: XConfig l -> [VirtualWorkspace]
workspaces' = nub . map (snd . unmarshall) . workspaces

withScreens :: ScreenId            -- ^ The number of screens to make workspaces for
            -> [VirtualWorkspace]  -- ^ The desired virtual workspace names
            -> [PhysicalWorkspace] -- ^ A list of all internal physical workspace names
withScreens n vws = [marshall sc pws | pws <- vws, sc <- [0..n-1]]

onCurrentScreen :: (VirtualWorkspace -> WindowSet -> a) -> (PhysicalWorkspace -> WindowSet -> a)
onCurrentScreen f vws = screen . current >>= f . flip marshall vws

-- | In case you don't know statically how many screens there will be, you can call this in main before starting xmonad.  For example, part of my config reads
--
-- > main = do
-- >   nScreens <- countScreens
-- >   xmonad $ defaultConfig {
-- >     ...
-- >     workspaces = withScreens nScreens (workspaces defaultConfig),
-- >     ...
-- >     }
--
countScreens :: (MonadIO m, Integral i) => m i
countScreens = liftM genericLength . liftIO $ openDisplay "" >>= getScreenInfo

-- TODO: documentation from here down
-- TODO: note somewhere that "marshall" functions go from convenient
--       to inconvenient, and "unmarshall" functions go from
--       inconvenient to convenient
marshallPP :: ScreenId -> PP -> PP
marshallPP s pp = pp {
    ppCurrent           = ppCurrent         pp . snd . unmarshall,
    ppVisible           = ppVisible         pp . snd . unmarshall,
    ppHidden            = ppHidden          pp . snd . unmarshall,
    ppHiddenNoWindows   = ppHiddenNoWindows pp . snd . unmarshall,
    ppUrgent            = ppUrgent          pp . snd . unmarshall,
    ppSort              = fmap (marshallSort s) (ppSort pp)
    }

marshallSort :: ScreenId -> ([WindowSpace] -> [WindowSpace]) -> ([WindowSpace] -> [WindowSpace])
marshallSort s vSort = pScreens . vSort . vScreens where
    onScreen ws = unmarshallS (tag ws) == s
    vScreens    = map unmarshallWindowSpace . filter onScreen
    pScreens    = map (marshallWindowSpace s)

marshallWindowSpace   :: ScreenId -> WindowSpace -> WindowSpace
unmarshallWindowSpace :: WindowSpace -> WindowSpace

marshallWindowSpace s ws = ws { tag = marshall s  (tag ws) }
unmarshallWindowSpace ws = ws { tag = unmarshallW (tag ws) }
