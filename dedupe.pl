#!/usr/bin/perl -w

sub usage 
{
print <<EOF

Version 3.4 - 20180621
This was written by Vittorio Tracy vrt\@srclab.com and is free to use or modify

ABOUT:
This script will compare the files in one or two directories to identify
duplicates and optionally operate on them. Files are compared by MD5 checksum.
Previously seen files can be stored in a text file for use in future comparisons.

The duplicates found can be deleted, or just displayed.
The destination directory is optional, but if supplied, the files in source
directory will be compared against the destination directory and the
non-duplicate files can be copied or moved into the destination directory,
effectively merging the directories together.

USAGE:
dedupe.pl [OPTIONS] sourcedir

  OPTIONS:
   -h          help, print this usage information and exit
   -f 	       only read files, skip directories (do not recurse)
   -v 	       verbose output 
   -l LISTFILE load a list of files with checksums instead or in addition to the sourcedir
   -s 	       store files not found in list
   -b 	       follow symbolic links when recursing (not recommended)
   TODO: -q    quick match, use filename and size only to match already seen files
   TODO: -p    prune empty directories in sourcedir (if previously not empty) 
   -e REGEX    exclude files/directories matching a regex pattern, ex: '\.svn\$', '\.old|\.bak'
   -a          do an accounting of files in the list not found during scan

  ACTIONS:
   -d          delete the duplicates found
   -c DESTDIR  copy the non duplicate files to the destination directory
   -m DESTDIR  move the non duplicate files to the destination directory

TODO:
  - Add multiprocessing support to speed up scans.
  - Support some other list storage formats or methods (SQL DB for example to reduce memory 
    use and support larger file lists).

EOF
}

# Required library modules
use Getopt::Std;
use Digest::MD5;
use File::Copy;

# Global variabls
my %md5map;
my %cmdopts;
my ($tLoaded, $tDirectories, $tFiles, $tInList, $tNew, $tMissing) = (0,0,0,0,0,0);
my @srcdir;

# Input processing
getopts('hafvdsbqe:l:m:c:', \%cmdopts);

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
&showmissing() if ($cmdopts{a});
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
   }
   $tLoaded = scalar keys(%md5map);
   print "Loaded $tLoaded files from list\n" if ($cmdopts{v}); 
}

# Traverse a directory recursively, calculating a MD5 checksum and other metadata
# and use that metadata to determine if the file is a duplicate. If the file is a
# duplicate, carry out the action desired.
# TODO: break out comparision operations into a separate subroutine
# TODO: break out action operations into separate subroutine
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
        print "   Calculating checksum for file: '$f':" if ($cmdopts{v});

        binmode(FILE);
        my $md5 = Digest::MD5->new->addfile(*FILE)->hexdigest;
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

            if ($cmdopts{d})
            {
                print " [Delete]";
                unlink $f or warn "Failed to unlink file '$f': $!";
            }
            print "\n";
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
            print " [New]\n" if ($cmdopts{v});
            $tNew++;

            if ($cmdopts{c}) {
                my ($ftmp) = $f =~ /([^\/]+)$/;
                my $cfile = $cmdopts{c} . $ftmp;
                #print "DEBUG: copying '$f' to '$cfile'\n";
                copy($f, $cfile) or warn "Failed to copy file '$f' to '$cmdopts{c}': $!";
            }
            if ($cmdopts{m}) {
                my ($ftmp) = $f =~ /([^\/]+)$/;
                my $mfile = $cmdopts{m} . $ftmp;
                #print "DEBUG: moving '$f' to '$mfile'\n";
                move($f, $mfile) or warn "Failed to move file '$f' to '$cmdopts{m}': $!";
            }
        }
    }
}

# List files seen previosly but not found during the current scan.
sub showmissing
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

