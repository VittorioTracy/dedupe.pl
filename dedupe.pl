#!/usr/bin/perl -w

# Constants
$VERSION = 3.5;

sub usage 
{
print <<EOF

Version $VERSION
This was written by Vittorio Tracy vrt\@srclab.com, free to be used under 
the terms of the MIT license.


ABOUT:
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


USAGE:
  dedupe.pl [OPTIONS] sourcedir [sourcedir ..]

  OPTIONS:
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

  ACTIONS:
   -d          delete the duplicates found
   -c DESTDIR  copy the non duplicate files to the destination directory
   -m DESTDIR  move the non duplicate files to the destination directory


LEGEND:
    
  In verbose mode each file found is listed with one or more of the following tags. The
  tags shown depend on whether the file match the checksum of a previosly seen file. The
  tag meaning is described for each below.

  CHECKSUM MATCH:
      [In-List]        The file checksum matches a file listed in the filelist.
      [New-Duplicate]  The file checksum is not in the filelist but has been seen.
      [Delete]         The file has been deleted.

  NO CHECKSUM MATCH:
      [New]            The file checksum is not in the filelist. 
      [Name-Duplicate] The file name is already in the filelist. 
      [Copy]           The file has been copied.
      [Move]           The file has been moved.


EXAMPLES:

Compare files in two directories testdir1 and testdir2 without using a filelist.
$ ./dedupe.pl -v testdir1/ testdir2

When using a filelist, if one doesn't already exist you must create one.
$ touch filelist.tsv

Scan a directory, testdir1, storing checksums in the filelist specified.
$ ./dedupe.pl -vs -l filelist.tsv testdir1/ 

Compare the files in a directory, testdir2, with the files previously seen and recorded in the filelist, filelist.tsv.
$ ./dedupe.pl -v -l filelist.tsv testdir2

Compare the files in a directory, testdir2, with the files previously seen and recorded in the filelist, filelist.tsv, and store new file checksums in the filelist. Also specified was the copy action option to copy non-duplicate files to the directory, nondupes.
$ mkdir nondupes
$ ./dedupe.pl -vs -l filelist.tsv -c nondupes/ testdir2/

Here is the result of the copy action.
$ ls nondupes/
hello  newfilehere


TODO:
  - Add multiprocessing support to speed up scans.
  - Support some other list storage formats or methods (SQL DB for example to reduce
    memory use and support larger file lists).

EOF
}

# Required library modules
use Getopt::Std;
use Digest::MD5;
use File::Copy;

# Global variabls
my %md5map;
my %namemap;
my %cmdopts;
my ($tLoaded, $tDirectories, $tFiles, $tInList, $tNew, $tMissing) = (0,0,0,0,0,0);
my @srcdir;

# Input processing
getopts('hafvdsobqe:l:m:c:', \%cmdopts);

if ($cmdopts{h}) { &usage(); exit(0) } # Print usage and exit

@srcdir = defined $ARGV[0] ? @ARGV : ['.'];

# Basic sanity checks
&error("Source directory is required") unless (scalar @ARGV);
foreach my $sd (@srcdir)
{
    $sd =~ s/(.+)\/+$/$1/; # remove any trailing slashes
    &error("Source directory is not a directory") unless (-d $sd);
}
&error("Copy destination directory is not a directory") if ($cmdopts{c} and !-d $cmdopts{c});
&error("Move destination directory is not a directory") if ($cmdopts{m} and !-d $cmdopts{m});


## 
# Main
## 

&loadfilelist({ list => $cmdopts{l} });
for my $sdir (@srcdir)
{
    &scandir({ dir => $sdir, delete => $cmdopts{d}, recurse => $cmdopts{f} });
}
&storefilelist({ list => $cmdopts{l} }) if ($cmdopts{s});
&missing() if ($cmdopts{a});
&totals() if ($cmdopts{v});

## 
# Subroutines
## 

# Display an error message and command usage.
sub error
{
   my $msg = shift;

   print "Error: $msg\n";
   &usage();
   exit(1);
}

# Store the list of seen files to a tab seperated text file.
# TODO: support some other list formats
sub storefilelist
{
   my $opts = shift;

   my $r = open(LIST, '>>', "$$opts{list}");
   die "List file '$$opts{list}' could not be opened: $!" unless ($r);

   foreach my $chksum (sort { $md5map{$a}{name} cmp $md5map{$b}{name} } keys %md5map)
   {
      next if ($md5map{$chksum}{stored});
      print LIST "$chksum\t$md5map{$chksum}{size}\t$md5map{$chksum}{modified}".
                 "\t$md5map{$chksum}{origpath}\t$md5map{$chksum}{origname}".
                 "\t$md5map{$chksum}{path}\t$md5map{$chksum}{name}\n";
      #print "DEBUG Storing: $chksum\t$md5map{$chksum}{name}\n" if ($cmdopts{v});
   }
}

# Load a list of previously seen files from a tab seperated text file.
# TODO: support some other list formats
sub loadfilelist
{
   my $opts = shift;

   return if (!defined $$opts{list});
   die "List file '$$opts{list}' not found" unless (-f $$opts{list});

   my $r = open(LIST, $$opts{list});
   die "List file '$$opts{list}' could not be opened: $!" unless ($r);

   foreach my $line (<LIST>)
   {
      next if ($line =~ /^#/);
      chomp($line);
      my ($chksum, $size, $modified, $origpath, $origname, $path, $filename) = split(/\t/, $line);
      $chksum =~ s/\s+//g if (defined $chksum);
      next unless (length $chksum and length $filename);
      #print "DEBUG Loaded: '$chksum' - '$filename'\n";
      #print "DEBUG '$filename' - file not found\n" unless (-f $filename);
      $md5map{$chksum} = { size => $size,
                           modified => $modified,
                           origpath => $origpath,
                           origname => $origname,
                           path => $path,
                           name => $filename,
                           stored => 1 };
      $namemap{$filename}{$chksum} = $path if ($cmdopts{v});
   }
   $tLoaded = scalar keys(%md5map);
   print "Loaded $tLoaded files from list\n" if ($cmdopts{v}); 
}

# Traverse a directory recursively, calculating a MD5 checksum and other metadata
# and use that metadata to determine if the file is a duplicate. If the file is a
# duplicate, carry out the action desired.
# TODO: break out comparision operations into a separate subroutine
sub scandir
{
    my $opts = shift;

    if (defined $cmdopts{e} and $$opts{dir} =~ /$cmdopts{e}/)
    {
        print "Directory '$$opts{dir}' matches exlude regex, skipping\n";
        return;
    }
 
    my $dres = opendir(DIR, $$opts{dir});
   
    if (!$$opts{seenfirst} and !$dres)
    { die "Directory '$$opts{dir}' cannot be opened: $!" }
    elsif ($$opts{seenfirst} and !$dres)
    {
        print "Error opening directory '$$opts{dir}', skipping: $!\n";
        return;
    }
    $tDirectories++;  
 
    print "Scanning directory '$$opts{dir}'\n" if ($cmdopts{v});
    my @items =  grep !/^\.\.?$/, readdir DIR;

    foreach (sort @items)
    {
        my $f = $$opts{dir} .'/'. $_;
        $f = $_ if ($$opts{dir} =~ /^(\.)|(\.\/)+$/); 

        if (-l $f and !$cmdopts{b})
        {
            print "  Skipping symbolic link: '$f'\n" if ($cmdopts{v});
            next;
        }

        if (-d $f)
        {
            if (!$cmdopts{r} or !$$opts{seenfirst})
            {
                if (defined $cmdopts{e} and $$opts{dir} =~ /$cmdopts{e}/)
                {
                    print "Directory '$$opts{dir}' matches exlude regex, skipping\n";
                    next;
                }
 
                #print "DEBUG: Recursing into directory: $f\n";
                $$opts{seenfirst} = 1;
                my $pdir = $$opts{dir};
                $$opts{dir} = $f;
                &scandir($opts);
                $$opts{dir} = $pdir; 
                next;
            }

            print "  Skipping directory: '$f'\n" if ($cmdopts{v});
            next;
        }
      
        unless (-f $f) { print "  Skipping, not a file or directory: '$f'\n" if ($cmdopts{v}); next }

        if (defined $cmdopts{e} and 
            $f =~ /$cmdopts{e}/) { print "  Skipping, File '$f' matches exlude regex\n"; next }

        unless (-s $f) { print "  Skipping, empty file: '$f'\n" if ($cmdopts{v}); next }

        unless (open(FILE, $f)) { print "Skipping, Error opening '$f': $!\n"; next }
      
        if ($cmdopts{l})
        {
            my $lstrip = $cmdopts{l};
            $lstrip =~ s/.*\/+//;
            my $fstrip = $f;
            $fstrip =~ s/.*\/+//;

            next if ($fstrip eq $lstrip); # skip checksum list file
        }

        $tFiles++;
        print "   Found file: '$f':" if ($cmdopts{v});

        binmode(FILE);
        my $md5 = Digest::MD5->new->addfile(*FILE)->hexdigest;
        my $isdupe = 0;
        if (defined $md5map{$md5}) # file is a duplicate
        {
            if ($md5map{$md5}{stored})
            {
                print " [In-List]" if ($cmdopts{v});
                $md5map{$md5}{seen} = 1;
            }
            else
            {
                print " [New-Duplicate]" if ($cmdopts{v});
            }

            $isdupe = 1; 
            $tInList++;
        }
        else # file is not a duplicate
        {
            $md5map{$md5}{path} = $$opts{dir} =~ /^(\.)|(\.\/)+$/ ? '' : $$opts{dir};
            $md5map{$md5}{name} = $_;
            $md5map{$md5}{origpath} = '';
            $md5map{$md5}{origname} = '';
            $md5map{$md5}{size} = (stat($f))[7];
            $md5map{$md5}{modified} = (stat(_))[9];
            print " [New]" if ($cmdopts{v});
            $tNew++;

            print " [Name-Duplicate]" if ($cmdopts{v} and defined $namemap{$_} and 
                                          not defined $namemap{$_}{$md5});
            $namemap{$_}{$md5} = $md5map{$md5}{path};
        }

        &action($f, $isdupe);
        print "\n" if ($cmdopts{v})
    }
}

# Run desired action against duplicate or nonduplicate file found during scan
sub action
{
    my ($file, $isdupe) = @_;

    if ($isdupe)
    {
        if ($cmdopts{d})
        {
            print " [Delete]";
            unlink $file or warn "Failed to unlink file '$file': $!";
        }
    }
    else
    {
        if ($cmdopts{c})
        {
            my ($ftmp) = $file =~ /([^\/]+)$/;
            my $cfile = $cmdopts{c} . $ftmp;
            $cfile = &unique($cfile) if not ($cmdopts{o});
            #print "DEBUG: copying '$file' to '$cfile'\n";
            print " [Copy]";
            copy($file, $cfile) or warn "Failed to copy file '$file' to '$cmdopts{c}': $!";
        }
        if ($cmdopts{m})
        {
            my ($ftmp) = $file =~ /([^\/]+)$/;
            my $mfile = $cmdopts{m} . $ftmp;
            $mfile = &unique($mfile) if not ($cmdopts{o});
            #print "DEBUG: moving '$file' to '$mfile'\n";
            print " [Move]";
            move($file, $mfile) or warn "Failed to move file '$file' to '$cmdopts{m}': $!";
        }
    }
} 

# Check that file with same name doesn't already exist in destination, 
# rename if one does (do not clobber)
sub unique
{
    my $dfile = shift;
    if (-e $dfile) {
        if ($dfile =~ /^(.*)\.(\d+)$/)
        {
            $dfile = $1 . '.' . ($2 + 1);
        }
        else 
        { 
            $dfile = $dfile . '.1';
        }

        $dfile = &unique($dfile);
    }

    return $dfile
}

# List files seen previosly but not found during the current scan.
sub missing
{
   print "\nFiles in the list not found during the scan:\n" if ($cmdopts{v});
   foreach my $md5 (keys %md5map)
   {
      next if ($md5map{$md5}{seen});
      my $fpath = length $md5map{$md5}{path} ? $md5map{$md5}{path} .'/' : '';
      print "   $fpath$md5map{$md5}{name}\n" if ($cmdopts{v});
      $tMissing++;
   }
   printf "%-32s %5d\n", 'Total missing files:', $tMissing;
}

# Report totals calculated for the current scan.
sub totals 
{
    print "\n";
    printf "%-32s %5d\n", 'Files loaded from list:', $tLoaded;
    printf "%-32s %5d\n", 'Directories scanned:', $tDirectories;
    printf "%-32s %5d\n", 'Files scanned:', $tFiles;
    printf "%-32s %5d\n", 'Files found already in the list:', $tInList;
    printf "%-32s %5d\n", 'New files found:', $tNew;
    print "\n";
}

