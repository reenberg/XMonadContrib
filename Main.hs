-----------------------------------------------------------------------------
-- |
-- Module      :  Main.hs
-- Copyright   :  (c) Spencer Janssen 2007
-- License     :  BSD3-style (see LICENSE)
-- 
-- Maintainer  :  sjanssen@cse.unl.edu
-- Stability   :  unstable
-- Portability :  not portable, uses mtl, X11, posix
--
-----------------------------------------------------------------------------
--
-- thunk, a minimal window manager for X11
--

import Data.Bits hiding (rotate)
import Data.List
import qualified Data.Sequence as S
import qualified Data.Foldable as F
import qualified Data.Map as M

import System.IO
import System.Process (runCommand)
import System.Exit

import Graphics.X11.Xlib
import Graphics.X11.Xlib.Extras

import Control.Monad.State

import W

--
-- The keys list
--
keys :: M.Map (KeyMask, KeySym) (W ())
keys = M.fromList
    [ ((mod1Mask .|. shiftMask, xK_Return), spawn "xterm")
    , ((mod1Mask,               xK_p     ), spawn "exe=`dmenu_path | dmenu` && exec $exe")
    , ((controlMask,            xK_space ), spawn "gmrun")
    , ((mod1Mask,               xK_Tab   ), focus 1)
    , ((mod1Mask,               xK_j     ), focus 1)
    , ((mod1Mask,               xK_k     ), focus (-1))
    , ((mod1Mask .|. shiftMask, xK_c     ), kill)
    , ((mod1Mask .|. shiftMask, xK_q     ), io $ exitWith ExitSuccess)

    , ((mod1Mask,               xK_1     ), view 1)
    , ((mod1Mask,               xK_2     ), view 2)
    , ((mod1Mask,               xK_3     ), view 3)
    , ((mod1Mask,               xK_4     ), view 4)
    , ((mod1Mask,               xK_5     ), view 5)

    ]

--
-- let's get underway
-- 
main :: IO ()
main = do
    dpy <- openDisplay ""
    let dflt      = defaultScreen dpy
        initState = WState
            { display      = dpy
            , screenWidth  = displayWidth  dpy dflt
            , screenHeight = displayHeight dpy dflt
            , workspace    = (0,S.fromList (replicate 5 []))
            }

    runW initState $ do
        r <- io $ rootWindow dpy dflt
        io $ do selectInput dpy r (substructureRedirectMask .|. substructureNotifyMask)
                sync dpy False
        registerKeys dpy r
        go dpy

    return ()
  where
    -- The main loop
    go dpy = forever $ do
        e <- io $ allocaXEvent $ \ev -> nextEvent dpy ev >> getEvent ev
        handle e

    -- register keys
    registerKeys dpy r = forM_ (M.keys keys) $ \(m,s) -> io $ do
        kc <- keysymToKeycode dpy s
        grabKey dpy kc m r True grabModeAsync grabModeAsync

--
-- | handle. Handle X events
-- 
handle :: Event -> W ()
handle (MapRequestEvent    {window = w}) = manage w
handle (DestroyWindowEvent {window = w}) = unmanage w
handle (UnmapEvent         {window = w}) = unmanage w

handle (KeyEvent {event_type = t, state = m, keycode = code})
    | t == keyPress = do
        dpy <- gets display
        s   <- io $ keycodeToKeysym dpy code 0
        case M.lookup (m,s) keys of
            Nothing -> return ()
            Just a  -> a

handle e@(ConfigureRequestEvent {}) = do
    dpy <- gets display
    io $ configureWindow dpy (window e) (value_mask e) $ WindowChanges
            { wcX           = x e
            , wcY           = y e
            , wcWidth       = width e
            , wcHeight      = height e
            , wcBorderWidth = border_width e
            , wcSibling     = above e
            , wcStackMode   = detail e
            }
    io $ sync dpy False

handle _ = return ()

-- ---------------------------------------------------------------------
-- Managing windows

--
-- | refresh. Refresh the currently focused window. Resizes to full
-- screen and raises the window.
--
refresh :: W ()
refresh = do
    (n,wks) <- gets workspace
    let ws = wks `S.index` n
    case ws of
        []    -> return ()  -- do nothing. hmm. so no empty workspaces?
                            -- we really need to hide all non-visible windows
                            -- ones on other screens
        (w:_) -> do
            d  <- gets display
            sw <- liftM fromIntegral (gets screenWidth)
            sh <- liftM fromIntegral (gets screenHeight)
            io $ do moveResizeWindow d w 0 0 sw sh -- size
                    raiseWindow d w

-- | Modify the current window list with a pure funtion, and refresh
withWindows :: (Windows -> Windows) -> W ()
withWindows f = do
    modifyWindows f
    refresh

-- | manage. Add a new window to be managed in the current workspace. Bring it into focus.
manage :: Window -> W ()
manage w = do
    d  <- gets display
    io $ mapWindow d w
    withWindows (nub . (w :))

-- | unmanage. A window no longer exists, remove it from the window
-- list, on whatever workspace
unmanage :: Window -> W ()
unmanage w = do
    (_,wks) <- gets workspace
    mapM_ rm (F.toList wks)
  where
    rm ws = when (w `elem` ws) $ do
                dpy     <- gets display
                io $ do grabServer dpy
                        sync dpy False
                        ungrabServer dpy
                withWindows $ filter (/= w)

-- | focus. focus to window at offset 'n' in list.
-- The currently focused window is always the head of the list
focus :: Int -> W ()
focus n = withWindows (rotate n)

-- | spawn. Launch an external application
spawn :: String -> W ()
spawn = io_ . runCommand

-- | Kill the currently focused client
kill :: W ()
kill = do
    dpy     <- gets display
    (n,wks) <- gets workspace
    let ws = wks `S.index` n
    case ws of
        []    -> return ()
        (w:_) -> do
        --  if(isprotodel(sel))
        --      sendevent(sel->win, wmatom[WMProtocols], wmatom[WMDelete]);
            io $ killClient dpy w -- ignoring result
            return ()

-- | Change the current workspace to workspce at offset 'n-1'.
view :: Int -> W ()
view n = return ()

--
-- So the problem is that I don't quite understand X here.
-- The following code will set the right list of windows to be current,
-- according to our view of things.
--
-- We just need to tell X that it is only those in the current window
-- list that are indeed visible, and everything else is hidden.
--
-- In particular, if we switch to a new empty workspace, nothing should
-- be visible but the root. So: how do we hide windows?
--
{- do
    let m = n-1
    modifyWorkspaces $ \old@(_,wks) ->
        if m < S.length wks && m >= 0 then (m,wks) else old
    refresh
-}
