{- git-annex command
 -
 - Copyright 2010-2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE BangPatterns #-}

module Command.Unused where

import qualified Data.Set as S
import qualified Data.Text.Lazy as L
import qualified Data.Text.Lazy.Encoding as L

import Common.Annex
import Command
import Annex.Content
import Utility.FileMode
import Utility.TempFile
import Logs.Location
import qualified Annex
import qualified Git
import qualified Git.Command
import qualified Git.Ref
import qualified Git.LsFiles as LsFiles
import qualified Git.LsTree as LsTree
import qualified Backend
import qualified Remote
import qualified Annex.Branch
import qualified Option
import Annex.CatFile

def :: [Command]
def = [withOptions [fromOption] $ command "unused" paramNothing seek
	"look for unused file content"]

fromOption :: Option
fromOption = Option.field ['f'] "from" paramRemote "remote to check for unused content"

seek :: [CommandSeek]
seek = [withNothing start]

{- Finds unused content in the annex. -} 
start :: CommandStart
start = do
	from <- Annex.getField $ Option.name fromOption
	let (name, action) = case from of
		Nothing -> (".", checkUnused)
		Just "." -> (".", checkUnused)
		Just "here" -> (".", checkUnused)
		Just n -> (n, checkRemoteUnused n)
	showStart "unused" name
	next action

checkUnused :: CommandPerform
checkUnused = do
	unused <- findunused =<< Annex.getState Annex.fast
	stalebad <- staleKeysPrune gitAnnexBadDir
	staletmp <- staleKeysPrune gitAnnexTmpDir
	_ <- list "" unusedMsg unused 0 >>=
		list "bad" staleBadMsg stalebad >>=
			list "tmp" staleTmpMsg staletmp
	next $ return True
	where
		findunused True = do
			showNote "fast mode enabled; only finding stale files"
			return []
		findunused False = do
			showAction "checking for unused data"
			excludeReferenced =<< getKeysPresent
		list file msg l c = do
			let unusedlist = number c l
			unless (null l) $ showLongNote $ msg unusedlist
			writeUnusedFile file unusedlist
			return $ c + length l

checkRemoteUnused :: String -> CommandPerform
checkRemoteUnused name = do
	checkRemoteUnused' =<< fromJust <$> Remote.byName (Just name)
	next $ return True

checkRemoteUnused' :: Remote -> Annex ()
checkRemoteUnused' r = do
	showAction "checking for unused data"
	remotehas <- loggedKeysFor (Remote.uuid r)
	remoteunused <- excludeReferenced remotehas
	let list = number 0 remoteunused
	writeUnusedFile "" list
	unless (null remoteunused) $ showLongNote $ remoteUnusedMsg r list

writeUnusedFile :: FilePath -> [(Int, Key)] -> Annex ()
writeUnusedFile prefix l = do
	logfile <- fromRepo $ gitAnnexUnusedLog prefix
	liftIO $ viaTmp writeFile logfile $
		unlines $ map (\(n, k) -> show n ++ " " ++ show k) l

table :: [(Int, Key)] -> [String]
table l = "  NUMBER  KEY" : map cols l
	where
		cols (n,k) = "  " ++ pad 6 (show n) ++ "  " ++ show k
		pad n s = s ++ replicate (n - length s) ' '

number :: Int -> [a] -> [(Int, a)]
number _ [] = []
number n (x:xs) = (n+1, x) : number (n+1) xs

staleTmpMsg :: [(Int, Key)] -> String
staleTmpMsg t = unlines $ 
	["Some partially transferred data exists in temporary files:"]
	++ table t ++ [dropMsg Nothing]

staleBadMsg :: [(Int, Key)] -> String
staleBadMsg t = unlines $ 
	["Some corrupted files have been preserved by fsck, just in case:"]
	++ table t ++ [dropMsg Nothing]

unusedMsg :: [(Int, Key)] -> String
unusedMsg u = unusedMsg' u
	["Some annexed data is no longer used by any files:"]
	[dropMsg Nothing]
unusedMsg' :: [(Int, Key)] -> [String] -> [String] -> String
unusedMsg' u header trailer = unlines $
	header ++
	table u ++
	["(To see where data was previously used, try: git log --stat -S'KEY')"] ++
	trailer

remoteUnusedMsg :: Remote -> [(Int, Key)] -> String
remoteUnusedMsg r u = unusedMsg' u
	["Some annexed data on " ++ name ++ " is not used by any files:"]
	[dropMsg $ Just r]
	where
		name = Remote.name r 

dropMsg :: Maybe Remote -> String
dropMsg Nothing = dropMsg' ""
dropMsg (Just r) = dropMsg' $ " --from " ++ Remote.name r
dropMsg' :: String -> String
dropMsg' s = "\nTo remove unwanted data: git-annex dropunused" ++ s ++ " NUMBER\n"

{- Finds keys in the list that are not referenced in the git repository. -}
excludeReferenced :: [Key] -> Annex [Key]
excludeReferenced [] = return [] -- optimisation
excludeReferenced l = do
	let s = S.fromList l
	!s' <- withKeysReferenced s S.delete
	go s' =<< refs <$> (inRepo $ Git.Command.pipeRead [Param "show-ref"])
	where
		-- Skip the git-annex branches, and get all other unique refs.
		refs = map (Git.Ref .  snd) .
			nubBy uniqref .
			filter ourbranches .
			map (separate (== ' ')) . lines
		uniqref (a, _) (b, _) = a == b
		ourbranchend = '/' : show Annex.Branch.name
		ourbranches (_, b) = not $ ourbranchend `isSuffixOf` b
		go s [] = return $ S.toList s
		go s (r:rs)
			| s == S.empty = return [] -- optimisation
			| otherwise = do
				s' <- withKeysReferencedInGit r s S.delete
				go s' rs

{- Finds items in the first, smaller list, that are not
 - present in the second, larger list.
 - 
 - Constructing a single set, of the list that tends to be
 - smaller, appears more efficient in both memory and CPU
 - than constructing and taking the S.difference of two sets. -}
exclude :: Ord a => [a] -> [a] -> [a]
exclude [] _ = [] -- optimisation
exclude smaller larger = S.toList $ remove larger $ S.fromList smaller
	where
		remove a b = foldl (flip S.delete) b a

{- Given an initial value, mutates it using an action for each
 - key referenced by symlinks in the git repo. -}
withKeysReferenced :: v -> (Key -> v -> v) -> Annex v
withKeysReferenced initial a = go initial =<< files
	where
		files = do
			top <- fromRepo Git.workTree
			inRepo $ LsFiles.inRepo [top]
		go v [] = return v
		go v (f:fs) = do
			x <- Backend.lookupFile f
			case x of
				Nothing -> go v fs
				Just (k, _) -> do
					let !v' = a k v
					go v' fs

withKeysReferencedInGit :: Git.Ref -> v -> (Key -> v -> v) -> Annex v
withKeysReferencedInGit ref initial a = do
	showAction $ "checking " ++ Git.Ref.describe ref
	go initial =<< inRepo (LsTree.lsTree ref)
	where
		go v [] = return v
		go v (l:ls)
			| isSymLink (LsTree.mode l) = do
				content <- L.decodeUtf8 <$> catFile ref (LsTree.file l)
				case fileKey (takeFileName $ L.unpack content) of
					Nothing -> go v ls
					Just k -> do
						let !v' = a k v
						go v' ls
			| otherwise = go v ls

{- Looks in the specified directory for bad/tmp keys, and returns a list
 - of those that might still have value, or might be stale and removable.
 - 
 - Also, stale keys that can be proven to have no value are deleted.
 -}
staleKeysPrune :: (Git.Repo -> FilePath) -> Annex [Key]
staleKeysPrune dirspec = do
	contents <- staleKeys dirspec
	
	dups <- filterM inAnnex contents
	let stale = contents `exclude` dups

	dir <- fromRepo dirspec
	liftIO $ forM_ dups $ \t -> removeFile $ dir </> keyFile t

	return stale

staleKeys :: (Git.Repo -> FilePath) -> Annex [Key]
staleKeys dirspec = do
	dir <- fromRepo dirspec
	exists <- liftIO $ doesDirectoryExist dir
	if not exists
		then return []
		else do
			contents <- liftIO $ getDirectoryContents dir
			files <- liftIO $ filterM doesFileExist $
				map (dir </>) contents
			return $ mapMaybe (fileKey . takeFileName) files
