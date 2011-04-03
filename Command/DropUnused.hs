{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.DropUnused where

import Control.Monad (when)
import Control.Monad.State (liftIO)
import qualified Data.Map as M
import System.Directory
import Data.Maybe

import Command
import Types
import Messages
import Locations
import qualified Annex
import qualified Command.Drop
import qualified Command.Move
import qualified Remote
import Backend
import Key

command :: [Command]
command = [repoCommand "dropunused" (paramRepeating paramNumber) seek
	"drop unused file content"]

seek :: [CommandSeek]
seek = [withUnusedMap]

{- Read unusedlog once, and pass the map to each start action. -}
withUnusedMap :: CommandSeek
withUnusedMap params = do
	m <- readUnusedLog
	return $ map (start m) params

start :: M.Map String Key -> CommandStartString
start m s = notBareRepo $ do
	case M.lookup s m of
		Nothing -> return Nothing
		Just key -> do
			showStart "dropunused" s
			from <- Annex.getState Annex.fromremote
			case from of
				Just name -> do
					r <- Remote.byName name
					return $ Just $ performRemote r key
				_ -> return $ Just $ perform key

{- drop both content in the backend and any tmp file for the key -}
perform :: Key -> CommandPerform
perform key = do
	g <- Annex.gitRepo
	let tmp = gitAnnexTmpLocation g key
	tmp_exists <- liftIO $ doesFileExist tmp
	when tmp_exists $ liftIO $ removeFile tmp
	backend <- keyBackend key
	Command.Drop.perform key backend (Just 0) -- force drop

performRemote :: Remote.Remote Annex -> Key -> CommandPerform
performRemote r key = do
	showNote $ "from " ++ Remote.name r ++ "..."
	return $ Just $ Command.Move.fromCleanup r True key

readUnusedLog :: Annex (M.Map String Key)
readUnusedLog = do
	g <- Annex.gitRepo
	let f = gitAnnexUnusedLog g
	e <- liftIO $ doesFileExist f
	if e
		then do
			l <- liftIO $ readFile f
			return $ M.fromList $ map parse $ lines l
		else return $ M.empty
	where
		parse line = (head ws, fromJust $ readKey $ unwords $ tail ws)
			where
				ws = words line
