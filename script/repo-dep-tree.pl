#!/usr/bin/perl

# read in list of repositories (in order)

# for each repo
  # get list of dependencies in repo, save in hashmap

# for each repo
  # for each pom.xml in repo
    # scan pom.xml for deps
    # for each dep found
      # check if dep is in repo-deps
      # if yes, 
        # add relationship: this-repo -> dep-repo (list: dep)

use Getopt::Std;
use Cwd             qw(abs_path);
use File::Basename  qw( dirname);
use File::Find;
use XML::Simple;
use Data::Dumper;

getopts('v');

my $verbose = 0;
if( $opt_v ) { 
  ++$verbose;
}

# variables

my $repo_file = "./repository-list.txt";
my (%repo_mods, %repo_deps, %mod_repos, %repo_tree, %repo_sorted);
my (@repo_list, @repo_sorted);
my ($repo, $dep, $branch_version);
my ($module, $xml, $data);

# subs

sub collectModules {
  unless( /^pom.xml$/ ) {
    return;
  }
  my $dir = $File::Find::dir;

  my $this_repo = $dir;
  $this_repo =~ s#/.*##;

  my $file = $File::Find::name;

  $xml = new XML::Simple;
  $data = $xml->XMLin($_);
  $module = getModule($data);

  # collect repo module info
  if( ! exists $repo_mods{$this_repo} ) { 
    $repo_mods{$this_repo} = {};
  }
  $repo_mods{$this_repo}->{$module} = 1;

  # collect repo dependency info
  my $dep_arr_ref = $data->{'dependencies'}->{'dependency'};
  if( ! defined $dep_arr_ref ) { 
    return;
  } elsif( $dep_arr_ref =~ /^HASH/ ) { 
    my $dep_id = "$dep_arr_ref->{'groupId'}:$dep_arr_ref->{'artifactId'}";
    if( ! exists $repo_deps{$dep_id} ) { 
      $repo_deps{$dep_id} = {};
    }
    $repo_deps{$dep_id}{$this_repo} = 1;
    return;
  } else { 
    foreach my $dep (@{$dep_arr_ref}) { 
      my $dep_id = "$dep->{'groupId'}:$dep->{'artifactId'}";
      if( ! exists $repo_deps{$dep_id} ) { 
        $repo_deps{$dep_id} = {};
      }
      $repo_deps{$dep_id}{$this_repo} = 1;
    }
  }
 
}

sub getModule() {
  my $xml_data = shift();

  my $groupId = $xml_data->{'groupId'};
  if( $groupId eq "" ) { 
    $groupId = $xml_data->{'parent'}->{'groupId'};
  }
  my $module = "$groupId:$xml_data->{'artifactId'}";

  # check version 
  my $version = $xml_data->{'version'};
  if( $version eq "" ) { 
    $version = $xml_data->{'parent'}->{'version'};
  }
  if( ! defined $branch_version ) { 
    $branch_version = $version;
  } elsif( $groupId !~ /^org.uberfire/ ) { 
    if( $branch_version ne $version ) { 
      die "Incorrect version ($version) for $module\n";
    }
  }

  return $module;
}

sub onlyLookAtPoms { 
  my @pom_files = grep { $_ =~ /pom.xml/ } @_;
  my @dirs = grep { -d $_ } @_;
  my @filesToProcess = ();

  foreach my $fileName ( "src", "target", "bin", "resources", "kie-eap-modules", "META-INF" ) { 
    @dirs = grep { ! ( $_ eq $fileName && -d $_ ) } @dirs;
  }

  @filesToProcess = (@pom_files, @dirs );

  return @filesToProcess;
}

# main

open(LIST, "<$repo_file" ) 
  || die "Unable to open $repo_file: $!\n";
while(<LIST>) { 
  chomp($_);
  push( @repo_list, $_ );
}
push( @repo_list, "uberfire" );

my $script_home_dir = dirname(abs_path($0));
chdir "$script_home_dir/../../";
my $root_dir = Cwd::getcwd();

my $repo;
for my $i (0 .. $#repo_list ) { 
  $repo = $repo_list[$i]; 

  if( ! -d $repo ) { 
    die "Could not find directory for repository '$repo' at $root_dir!\n";
  } 

  find( {
    wanted => \&collectModules, 
    preprocess => \&onlyLookAtPoms
    }, $repo);
}

print "- Finished collecting module information.\n";

foreach $repo (keys %repo_mods) { 
  foreach $dep (keys %{$repo_mods{$repo}}) { 
    if( exists $mod_repos{$dep} ) { 
      print "The $dep module exists in both the $mod_repos{$dep} AND $repo repositories!\n";
    } else { 
      $mod_repos{$dep} = $repo;
    }
  }
}

print "- Finished ordering module information.\n";

# repo_deps : dependency -> repository in which the dependency is used (dependent)
# mod_repos : module -> repository in which the module is located (source) 
foreach $dep (keys %repo_deps ) { 
  foreach my $dep_repo (keys %{$repo_deps{$dep}}) { 
    if( exists $mod_repos{$dep} ) { 
      my $src_repo = $mod_repos{$dep};
      if( $src_repo eq $dep_repo ) { 
        next;
      }
      if( ! exists $repo_tree{$dep_repo} ) { 
        # $repo_tree{$dep_repo} = {};
        $repo_tree{$dep_repo} = {};
      } 
      if( $verbose ) { 
      $dep =~ s/^[^:]*://;
        if( ! exists $repo_tree{$dep_repo}{$src_repo} ) {  
          $repo_tree{$dep_repo}{$src_repo} = "$dep";
        } else { 
          $repo_tree{$dep_repo}{$src_repo} .= ",$dep";
        }
      } else { 
        ++$repo_tree{$dep_repo}{$src_repo};
      }
    }
  }
}

print "- Finished creating repository dependency tree.\n";

my %build_tree;

print "\nDependent-on tree: \n";
foreach $repo (@repo_list) { 
  print "\n$repo (is dependent on): \n";
  foreach my $leaf_repo (keys %{$repo_tree{$repo}} ) { 
    print "- $leaf_repo ($repo_tree{$repo}{$leaf_repo})\n";
    if( ! exists $build_tree{$leaf_repo} ) { 
      $build_tree{$leaf_repo} = {};
    }
    ++$build_tree{$leaf_repo}{$repo};
  }
}

print "\nDependencies tree: \n";
foreach $repo (keys %build_tree) { 
  print "\n$repo (is used by): \n";
  foreach my $leaf_repo (keys %{$build_tree{$repo}} ) { 
    print "- $leaf_repo\n";
  }
}
