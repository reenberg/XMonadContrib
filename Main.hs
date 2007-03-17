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
-- xmonad, a minimal window manager for X11
--

import Data.List
import Data.Maybe
import Data.Bits hiding (rotate)
import qualified Data.Map as M

import System.IO
import System.Exit

import Graphics.X11.Xlib
import Graphics.X11.Xlib.Extras
import Graphics.X11.Xinerama

import Control.Monad.State

import XMonad
import qualified StackSet as W

--
-- The number of workspaces:
--
workspaces :: Int
workspaces = 9

--
-- modMask lets you easily change which modkey you use.
--
modMask :: KeyMask
modMask = mod1Mask

--
-- The keys list
--
keys :: M.Map (KeyMask, KeySym) (X ())
keys = M.fromList $
    [ ((modMask .|. shiftMask, xK_Return), spawn "xterm")
    , ((modMask,               xK_p     ), spawn "exe=`dmenu_path | dmenu` && exec $exe")
    , ((controlMask,           xK_space ), spawn "gmrun")
    , ((modMask,               xK_Tab   ), raise GT)
    , ((modMask,               xK_j     ), raise GT)
    , ((modMask,               xK_k     ), raise LT)
    , ((modMask .|. shiftMask, xK_c     ), kill)
    , ((modMask .|. shiftMask, xK_q     ), io $ exitWith ExitSuccess)
    ] ++
    -- generate keybindings to each workspace:
    [((m .|. modMask, xK_0 + fromIntegral i), f i)
        | i <- [1 .. workspaces]
        , (f, m) <- [(view, 0), (tag, shiftMask)]]

--
-- The main entry point
-- 
main :: IO ()
main = do
    dpy   <- openDisplay ""
    let dflt = defaultScreen dpy
    rootw  <- rootWindow dpy dflt
    wmdelt <- internAtom dpy "WM_DELETE_WINDOW" False
    wmprot <- internAtom dpy "WM_PROTOCOLS"     False
    xinesc <- getScreenInfo dpy

    let st = XState
            { display      = dpy
            , screen       = dflt
	    , xineScreens  = xinesc
	    , wsOnScreen   = M.fromList $ map ((\n -> (n,n)) . fromIntegral . xsi_screen_number) xinesc 
            , theRoot      = rootw
            , wmdelete     = wmdelt
            , wmprotocols  = wmprot
            , dimensions   = (displayWidth  dpy dflt, displayHeight dpy dflt)
            , workspace    = W.empty workspaces
            }

    xSetErrorHandler -- in C, I'm too lazy to write the binding

    -- setup initial X environment
    sync dpy False
    selectInput dpy rootw $  substructureRedirectMask
                         .|. substructureNotifyMask
                         .|. enterWindowMask
                         .|. leaveWindowMask
    grabKeys dpy rootw
    sync dpy False

    ws <- scan dpy rootw
    allocaXEvent $ \e ->
        runX st $ do
            mapM_ manage ws
            forever $ handle =<< xevent dpy e
      where
        xevent d e = io (nextEvent d e >> getEvent e)
        forever a = a >> forever a

-- ---------------------------------------------------------------------
-- IO stuff. Doesn't require any X state
-- Most of these things run only on startup (bar grabkeys)

-- | scan for any initial windows to manage
scan :: Display -> Window -> IO [Window]
scan dpy rootw = do
    (_, _, ws) <- queryTree dpy rootw
    filterM ok ws
  where
    ok w = do wa <- getWindowAttributes dpy w
              return $ not (waOverrideRedirect wa)
                     && waMapState wa == waIsViewable

-- | Grab the keys back
grabKeys :: Display -> Window -> IO ()
grabKeys dpy rootw = do
    ungrabKey dpy '\0' {-AnyKey-} anyModifier rootw
    forM_ (M.keys keys) $ \(mask,sym) -> do
         kc <- keysymToKeycode dpy sym
         mapM_ (grab kc) [mask, mask .|. lockMask] -- note: no numlock
  where
    grab kc m = grabKey dpy kc m rootw True grabModeAsync grabModeAsync

-- ---------------------------------------------------------------------
-- Event handler
--
-- | handle. Handle X events
--
-- Events dwm handles that we don't:
--
--    [ButtonPress]    = buttonpress,
--    [Expose]         = expose,
--    [PropertyNotify] = propertynotify,
--
-- Todo: seperate IO from X monad stuff. We want to be able to test the
-- handler, and client functions, with dummy X interface ops, in QuickCheck
--
-- Will require an abstract interpreter from Event -> X Action, which
-- modifies the internal X state, and then produces an IO action to
-- evaluate.
--
-- XCreateWindowEvent(3X11)
-- Window manager clients normally should ignore this window if the
-- override_redirect member is True.
-- 
handle :: Event -> X ()

-- run window manager command
handle (KeyEvent {event_type = t, state = m, keycode = code})
    | t == keyPress
    = withDisplay $ \dpy -> do
        s   <- io $ keycodeToKeysym dpy code 0
        whenJust (M.lookup (m,s) keys) id

-- manage a new window
handle (MapRequestEvent    {window = w}) = withDisplay $ \dpy -> do
    wa <- io $ getWindowAttributes dpy w -- ignore override windows
    when (not (waOverrideRedirect wa)) $ manage w

-- window destroyed, unmanage it
handle (DestroyWindowEvent {window = w}) = do b <- isClient w; when b $ unmanage w

-- window gone, unmanage it
handle (UnmapEvent         {window = w}) = do b <- isClient w; when b $ unmanage w

-- set keyboard mapping
handle e@(MappingNotifyEvent {window = w}) = do
    let m = (request e, first_keycode e, count e)
    io $ refreshKeyboardMapping m
    when (request e == mappingKeyboard) $ withDisplay $ io . flip grabKeys w

-- entered a normal window
handle e@(CrossingEvent {window = w, event_type = t})
    | t == enterNotify  && mode e == notifyNormal && detail e /= notifyInferior
    = do ws <- gets workspace
	 case W.lookup w ws of
	      Just n  -> do setFocus w
			    windows $ W.view n
	      Nothing -> do b <- isRoot w
			    when b setTopFocus

-- left a window, check if we need to focus root
handle e@(CrossingEvent {event_type = t})
    | t == leaveNotify
    = do rootw <- gets theRoot
         when (window e == rootw && not (same_screen e)) $ setFocus rootw

-- configure a window
handle e@(ConfigureRequestEvent {window = w}) = do
    dpy <- gets display
    ws  <- gets workspace

    when (W.member w ws) $ -- already managed, reconfigure (see client:configure() 
        trace ("Reconfigure already managed window: " ++ show w)

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

handle e = trace (eventName e) -- ignoring

-- ---------------------------------------------------------------------
-- Managing windows

-- | refresh. Refresh the currently focused window. Resizes to full
-- screen and raises the window.
refresh :: X ()
refresh = do
    ws <- gets workspace
    ws2sc <- gets wsOnScreen
    xinesc <- gets xineScreens
    forM_ (M.assocs ws2sc) $ \(n, scn) -> 
	whenJust (listToMaybe $ W.index n ws) $ \w -> withDisplay $ \d -> do
	    let sc = xinesc !! scn
	    io $ do moveResizeWindow d w (fromIntegral $ xsi_x_org sc) 
					 (fromIntegral $ xsi_y_org sc)
					 (fromIntegral $ xsi_width sc)
					 (fromIntegral $ xsi_height sc) -- fullscreen
		    raiseWindow d w
    whenJust (W.peek ws) setFocus

-- | windows. Modify the current window list with a pure function, and refresh
windows :: (WorkSpace -> WorkSpace) -> X ()
windows f = do
    modify $ \s -> s { workspace = f (workspace s) }
    refresh
    ws <- gets workspace
    trace (show ws) -- log state changes to stderr

-- | hide. Hide a window by moving it offscreen.
hide :: Window -> X ()
hide w = withDisplay $ \d -> do
    (sw,sh) <- gets dimensions
    io $ moveWindow d w (2*fromIntegral sw) (2*fromIntegral sh)

-- ---------------------------------------------------------------------
-- Window operations

-- | manage. Add a new window to be managed in the current workspace. Bring it into focus.
-- If the window is already under management, it is just raised.
--
-- When we start to manage a window, it gains focus.
--
manage :: Window -> X ()
manage w = do
    withDisplay $ \d -> io $ do
        selectInput d w $ structureNotifyMask .|. enterWindowMask .|. propertyChangeMask
        mapWindow d w
    setFocus w
    windows $ W.push w

-- | unmanage. A window no longer exists, remove it from the window
-- list, on whatever workspace it is.
unmanage :: Window -> X ()
unmanage w = do
    modify $ \s -> s { workspace = W.delete w (workspace s) }
    withServerX $ do
      setTopFocus
      withDisplay $ \d -> io (sync d False)
      -- TODO, everything operates on the current display, so wrap it up.

-- | Grab the X server (lock it) from the X monad
withServerX :: X () -> X ()
withServerX f = withDisplay $ \dpy -> do
    io $ grabServer dpy
    f
    io $ ungrabServer dpy

-- | Explicitly set the keyboard focus to the given window
setFocus :: Window -> X ()
setFocus w = withDisplay $ \d -> io $ setInputFocus d w revertToPointerRoot 0

-- | Set the focus to the window on top of the stack, or root
setTopFocus :: X ()
setTopFocus = do
    ws <- gets workspace
    case W.peek ws of
        Just new -> setFocus new
        Nothing  -> gets theRoot >>= setFocus

-- | raise. focus to window at offset 'n' in list.
-- The currently focused window is always the head of the list
raise :: Ordering -> X ()
raise = windows . W.rotate

-- | Kill the currently focused client
kill :: X ()
kill = withDisplay $ \d -> do
    ws <- gets workspace
    whenJust (W.peek ws) $ \w -> do
        protocols <- io $ getWMProtocols d w
        wmdelt    <- gets wmdelete
        wmprot    <- gets wmprotocols
        if wmdelt `elem` protocols
            then io $ allocaXEvent $ \ev -> do
                    setEventType ev clientMessage
                    setClientMessageEvent ev w wmprot 32 wmdelt 0
                    sendEvent d w False noEventMask ev
            else io (killClient d w) >> return ()

-- | tag. Move a window to a new workspace
tag :: Int -> X ()
tag o = do
    ws <- gets workspace
    let m = W.current ws
    when (n /= m) $
        whenJust (W.peek ws) $ \w -> do
	    hide w
            windows $ W.shift n
    where n = o-1

-- | view. Change the current workspace to workspce at offset 'n-1'.
view :: Int -> X ()
view o = do
    ws <- gets workspace
    ws2sc <- gets wsOnScreen
    let m = W.current ws
    when (n /= m) $ do
	-- is the workspace we want to switch to currently visible?
	if M.member n ws2sc
	    then windows $ W.view n
	    else do 
		-- This assumes that the current workspace is visible.
		-- Is that always going to be true?
		let Just curscreen = M.lookup m ws2sc
		modify $ \s -> s { wsOnScreen = M.insert n curscreen (M.delete m ws2sc) }
		windows $ W.view n
		mapM_ hide (W.index m ws)
	setTopFocus
    where n = o-1

-- | True if window is under management by us
isClient :: Window -> X Bool
isClient w = liftM (W.member w) (gets workspace)
