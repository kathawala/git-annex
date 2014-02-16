{- metadata based branch views
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Annex.View where

import Common.Annex
import Logs.MetaData
import Types.MetaData
import qualified Git.Types as Git
import qualified Git.Ref
import qualified Git.DiffTree
import qualified Git.Branch
import qualified Git.Index
import Git.Sha (nullSha)
import Utility.QuickCheck

import qualified Data.Set as S
import Data.Char

#ifdef WITH_TDFA
import Text.Regex.TDFA
import Text.Regex.TDFA.String
#endif

type View = [(MetaField, ViewFilter)]

data ViewFilter
	= FilterValues (S.Set MetaValue)
#ifdef WITH_TDFA
	| FilterGlob String Regex
#endif

instance Show ViewFilter where
	show (FilterValues s) = show s
	show (FilterGlob s _) = s

instance Eq ViewFilter where
	FilterValues x == FilterValues y = x == y
	FilterGlob x _ == FilterGlob y _ = x == y
	_ == _ = False

instance Arbitrary ViewFilter where
	arbitrary = do
		size <- arbitrarySizedBoundedIntegral `suchThat` (< 100)
		FilterValues . S.fromList <$> vector size

{- Can a ViewFilter match multiple different MetaValues? -}
multiValue :: ViewFilter -> Bool
multiValue (FilterValues s) = S.size s > 1
#ifdef WITH_TDFA
multiValue (FilterGlob _ _) = True
#endif

type FileView = FilePath
type MkFileView = FilePath -> FileView

{- Checks if metadata matches a filter, and if so returns the value,
 - or values that match. -}
matchFilter :: MetaData -> MetaField -> ViewFilter -> Maybe [MetaValue]
matchFilter metadata metafield (FilterValues s) = nonEmptyList $
	S.intersection s (currentMetaDataValues metafield metadata)
#ifdef WITH_TDFA
matchFilter metadata metafield (FilterGlob _ r) = nonEmptyList $
	S.filter matching (currentMetaDataValues metafield metadata)
  where
	matching = either (const False) (const True) . execute r . fromMetaValue
#endif

nonEmptyList :: S.Set a -> Maybe [a]
nonEmptyList s
	| S.null s = Nothing
	| otherwise = Just $ S.toList s

{- Converts a filepath used in a reference branch to the
 - filename that will be used in the view.
 -
 - No two filenames from the same branch should yeild the same result,
 - so all directory structure needs to be included in the output file
 - in some way. However, the branch's directory structure is not relevant
 - in the view.
 -
 - So, from dir/subdir/file.foo, generate file(dir)(subdir).foo
 -}
fileViewFromReference :: MkFileView
fileViewFromReference f = base ++ concatMap (\d -> "(" ++ d ++ ")") dirs ++ concat extensions
  where
	(path, basefile) = splitFileName f
	dirs = filter (/= ".") $ map dropTrailingPathSeparator (splitPath path)
	(base, extensions) = splitShortExtensions basefile

{- Generates views for a file from a branch, based on its metadata
 - and the filename used in the branch.
 -
 - Note that a file may appear multiple times in a view, when it
 - has multiple matching values for a MetaField used in the View.
 -}
fileViews :: View -> MkFileView -> FilePath -> MetaData -> Maybe [FileView]
fileViews view mkfileview file metadata
	| any isNothing matches = Nothing
	| otherwise = Just $ map (</> mkfileview file) $
		pathProduct $ map (map fromMetaValue) $ visible matches
  where
  	matches :: [Maybe [MetaValue]]
	matches = map (uncurry $ matchFilter metadata) view
	visible :: [Maybe [MetaValue]] -> [[MetaValue]]
	visible = map (fromJust . snd) .
		filter (multiValue . fst) .
		zip (map snd view)

pathProduct :: [[FilePath]] -> [FilePath]
pathProduct [] = []
pathProduct (l:ls) = foldl combinel l ls
  where
	combinel xs ys = [combine x y | x <- xs, y <- ys]

{- Extracts the metadata from a fileview, based on the view that was used
 - to construct it. -}
fromView :: View -> FileView -> MetaData
fromView view f = foldr (uncurry updateMetaData) newMetaData (zip fields values)
  where
	visible = filter (multiValue . snd) view
	fields = map fst visible
	paths = splitDirectories $ dropFileName f
	values = map toMetaValue paths

{- Generates a git branch name for a View.
 - 
 - There is no guarantee that each view gets a unique branch name,
 - but the branch name is used to express the view as well as possible.
 -}
branchView :: View -> Git.Branch
branchView view
	| null name = Git.Ref "refs/views"
	| otherwise = Git.Ref $ "refs/views/" ++ name
  where
	name = intercalate "/" $ map branchbit view
	branchbit b@(_metafield, viewfilter)
		| multiValue viewfilter = branchbit' b
		| otherwise = "(" ++ branchbit' b ++ ")"
	branchbit' (metafield, viewfilter)
		| metafield == tagMetaField = branchvals viewfilter
		| otherwise = concat
			[ forcelegal (fromMetaField metafield)
			, "="
			, branchvals viewfilter
			]
	branchvals (FilterValues set) = forcelegal $
		intercalate "," $ map fromMetaValue $ S.toList set
#ifdef WITH_TDFA
	branchvals (FilterGlob glob _) = forcelegal $
		replace "*" "ANY" $ replace "?" "_" glob
#endif
	forcelegal s
		| Git.Ref.legal True s = s
		| otherwise = map (\c -> if isAlphaNum c then c else '_') s

prop_branchView_legal :: View -> Bool
prop_branchView_legal = Git.Ref.legal False . show . branchView

{- Applies a view to the currently checked out branch, generating a new
 - branch for the view.
 -}
applyView :: View -> Annex Git.Branch
applyView = applyView' fileViewFromReference

{- Generates a new branch for a View, which must be a more specific
 - version of the View originally used to generate the currently
 - checked out branch.
 -}
refineView :: View -> Annex Git.Branch
refineView = applyView' id

{- Go through each file in the currently checked out branch.
 - If the file is not annexed, skip it, unless it's a dotfile in the top.
 - Look up the metadata of annexed files, and generate any FileViews,
 - and stage them into the (temporary) index.
 -}
applyView' :: MkFileView -> View -> Annex Git.Branch
applyView' mkfileview view = genViewBranch view $ do
	error "TODO"

{- Applies a view to the reference branch, generating a new branch
 - for the View.
 -
 - This needs to work incrementally, to quickly update the view branch
 - when the reference branch is changed. So, it works based on an
 - old version of the reference branch, uses diffTree to find the
 - changes, and applies those changes to the view branch.
 -}
updateView :: View -> Git.Ref -> Git.Ref -> Annex Git.Branch
updateView view ref oldref = genViewBranch view $ do
	(diffs, cleanup) <- inRepo $ Git.DiffTree.diffTree oldref ref
	forM_ diffs go
	void $ liftIO cleanup
  where
	go diff
		| Git.DiffTree.dstsha diff == nullSha = error "TODO delete file"
		| otherwise = error "TODO add file"

{- Generates a branch for a view. This is done by creating a temporary
 - index file, which starts off empty. An action is run to stage the files
 - that will be in the branch. Then a commit is made, to the view branch.
 - The view branch is not checked out, but entering it will display the
 - view. -}
genViewBranch :: View -> Annex () -> Annex Git.Branch
genViewBranch view a = withTempIndex $ do
	a
	let branch = branchView view
	void $ inRepo $ Git.Branch.commit True (show branch) branch []
	return branch

{- -}
withTempIndex :: Annex a -> Annex a
withTempIndex a = error "TODO"
