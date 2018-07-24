This was written by Vittorio Tracy vrt@srclab.com, free to be used under 
the terms of the MIT license.

# ABOUT:
This script will compare the files in one or two directories to identify
duplicates and optionally operate on them. Files are compared by MD5 checksum.
Previously seen files can be stored in a text file for use in future comparisons.
Empty files are ignored.

The duplicates found can be deleted, or just displayed.
The destination directory is optional, but if supplied, the files in source
directory will be compared against the destination directory and the
non-duplicate files can be copied or moved into the destination directory,
effectively merging the directories together.

I use this script to manage my personal media, keeping track of which files I have copied from my camera or phone, even if I have deleted some because they were blurry.

# USAGE:
    dedupe.pl [OPTIONS] sourcedir [sourcedir ..]

## OPTIONS:
    -h          help, print this usage information and exit
    -f 	       only read files, skip directories (do not recurse)
    -v 	       verbose output 
    -l LISTFILE load a list of files with checksums instead or in addition to the sourcedir
    -s 	       store files not found in list (non duplicates)
    -b 	       follow symbolic links when recursing (not recommended)
    TODO: -q    quick match, use filename and size only to match already seen files
    TODO: -p    prune empty directories in sourcedir (if previously not empty) 
    -e REGEX    exclude files/directories matching a regex, ex: '\.svn\$', '\.old|\.bak'
    -a          do an accounting of files in the list not found during scan
    -o          overwrite on move/copy if file with same name exists at destination (clobber)

## ACTIONS:
    -d          delete the duplicates found
    -c DESTDIR  copy the non duplicate files to the destination directory
    -m DESTDIR  move the non duplicate files to the destination directory

# OUTPUT LEGEND:
    
  In verbose mode each file found is listed with one or more of the following tags. The
  tags shown depend on whether the file match the checksum of a previosly seen file. The
  tag meaning is described for each below.

## CHECKSUM MATCH:
**[In-List]**        The file checksum matches a file listed in the filelist.
**[New-Duplicate]**  The file checksum is not in the filelist but has been seen.
**[Delete]**         The file has been deleted.

## NO CHECKSUM MATCH:
**[New]**            The file checksum is not in the filelist. 
**[Name-Duplicate]** The file name is already in the filelist. 
**[Copy]**           The file has been copied.
**[Move]**           The file has been moved.


# EXAMPLES:

## Example 1
Compare files in two directories testdir1 and testdir2 without using a filelist.

    $ ./dedupe.pl -v testdir1/ testdir2
    Scanning directory 'testdir1'
       Found file: 'testdir1/hello': [New]
       Found file: 'testdir1/there': [New]
    Scanning directory 'testdir1/wat'
       Found file: 'testdir1/wat/saywat': [New]
    Scanning directory 'testdir2'
       Found file: 'testdir2/hello': [New] [Name-Duplicate]
       Found file: 'testdir2/newfilehere': [New]
       Found file: 'testdir2/saywatcopy': [New-Duplicate]

    Files loaded from list:              0
    Directories scanned:                 3
    Files scanned:                       6
    Files found already in the list:     1
    New files found:                     5

## Example 2
When using a filelist, if one doesn't already exist you must create one.
    
    $ touch filelist.tsv

Scan a directory, testdir1, storing checksums in the filelist specified.
    
    $ ./dedupe.pl -vs -l filelist.tsv testdir1/ 
    Loaded 0 files from list
    Scanning directory 'testdir1'
       Found file: 'testdir1/hello': [New]
       Found file: 'testdir1/there': [New]
    Scanning directory 'testdir1/wat'
       Found file: 'testdir1/wat/saywat': [New]

    Files loaded from list:              0
    Directories scanned:                 2
    Files scanned:                       3
    Files found already in the list:     0
    New files found:                     3

## Example 3
Compair the files in a directory, testdir2, with the files previously seen and recorded in the filelist, filelist.tsv.
    
    $ ./dedupe.pl -v -l filelist.tsv testdir2
    Loaded 3 files from list
    Scanning directory 'testdir2'
       Found file: 'testdir2/hello': [New] [Name-Duplicate]
       Found file: 'testdir2/newfilehere': [New]
       Found file: 'testdir2/saywatcopy': [In-List]

    Files loaded from list:              3
    Directories scanned:                 1
    Files scanned:                       3
    Files found already in the list:     1
    New files found:                     2

## Example 4
Compare the files in a directory, testdir2, with the files previously seen and recorded in the filelist, filelist.tsv, and store new file checksums in the filelist. Also specified was the copy action option to copy non-duplicate files to the directory, nondupes.
    
    $ mkdir nondupes
    $ ./dedupe.pl -vs -l filelist.tsv -c nondupes/ testdir2/
    Loaded 3 files from list
    Scanning directory 'testdir2'
       Found file: 'testdir2/hello': [New] [Name-Duplicate] [Copy]
       Found file: 'testdir2/newfilehere': [New] [Copy]
       Found file: 'testdir2/saywatcopy': [In-List]

    Files loaded from list:              3
    Directories scanned:                 1
    Files scanned:                       3
    Files found already in the list:     1
    New files found:                     2
Here is the result of the copy action.
    
    $ ls nondupes/
    hello  newfilehere
