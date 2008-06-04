package Dist::Zilla;
# ABSTRACT: distribution builder; installer not included!
use Moose;
use Moose::Autobox;
use MooseX::Types::Path::Class qw(Dir File);
use Moose::Util::TypeConstraints;

use File::Find::Rule;
use Path::Class ();
use Software::License;

use Dist::Zilla::Config;

use Dist::Zilla::File::OnDisk;
use Dist::Zilla::Role::Plugin;

has name => (
  is   => 'ro',
  isa  => 'Str',
  required => 1,
);

# XXX: *clearly* this needs to be really much smarter -- rjbs, 2008-06-01
has version => (
  is   => 'rw',
  isa  => 'Str',
  required => 1,
);

has abstract => (
  is   => 'rw',
  isa  => 'Str',
  lazy => 1,
  required => 1,
  default  => sub {
    my ($self) = @_;
    my $file = $self->files
             ->map (sub {$_->name})
             ->grep(sub {/\.pm$/})
             ->sort(sub{length $_[0] <=> length $_[1]})
             ->head;

    Carp::confess("couldn't find source for abstract file") unless $file;

    $self->_extract_abstract($file);
  }
);

# stolen from App::Cmd::Command, which stole from ExtUtils::MakeMaker
sub _extract_abstract {
  my ($self, $pm_file) = @_;

  my $result;
  open my $fh, "<", $pm_file or return "(unknown)";

  local $/ = "\n";
  my $inpod;

  my $class;
  while (local $_ = <$fh>) {
    chomp;
    # if (my ($x) = /^\s*#+\s*ABSTRACT:\s*(.+)$/) { $result = '1'; last };

    # =cut toggles, it doesn 't end :-/
    $inpod = /^=cut/ ? !$inpod : $inpod || /^=(?!cut)/;

    if (!$inpod) {
      /^\s*package (\S+)?;/;
      $class = $1 if $1;
      next;
    }

    next unless $class and /^(?:$class\s-\s)(.*)/;
    $result = $1;
    last;
  }

  return $result || "could not extract abstract from $pm_file";
}


has copyright_holder => (
  is   => 'ro',
  isa  => 'Str',
  required => 1,
);

has copyright_year => (
  is   => 'ro',
  isa  => 'Int',
  default => (localtime)[5] + 1900,
);

has license => (
  is   => 'ro',
  isa  => 'Software::License',
);

has authors => (
  is   => 'ro',
  isa  => 'ArrayRef[Str]',
  required => 1,
);

has build_root => (
  is   => 'ro',
  isa  => Dir,
  lazy    => 1,
  default => sub { Path::Class::dir('build') },
);

sub from_dir {
  my ($class, $root) = @_;

  $root = Path::Class::dir($root) unless ref $root;

  my $config_file = $root->file('dist.ini');
  my $config = Dist::Zilla::Config->read_file($config_file);

  my $plugins = delete $config->{plugins};

  my $license_name  = delete $config->{license};
  my $license_class = "Software::License::$license_name";

  eval "require $license_class; 1" or die;

  my $self = $class->new($config->merge({ root => $root }));

  my $license = $license_class->new({
    holder => $self->copyright_holder,
    year   => $self->copyright_year,
  });

  # XXX: fix this -- rjbs, 2008-06-01
  $self->{license} = $license;

  for my $plugin (@$plugins) {
    my ($plugin_class, $arg) = @$plugin;
    $self->plugins->push(
      $plugin_class->new( $arg->merge({ zilla => $self }) )
    );
  }

  return $self;
}

has plugins => (
  is   => 'ro',
  isa  => 'ArrayRef[Dist::Zilla::Role::Plugin]',
  default => sub { [ ] },
);

has files => (
  is   => 'ro',
  isa  => 'ArrayRef[Dist::Zilla::Role::File]',
  lazy => 1,
  default => sub {
    my ($self) = @_;
    my $root = $self->root;
    my @files = File::Find::Rule
              ->not( File::Find::Rule->name(qr/^\./) )
              ->file
              ->in($root);

    return @files->map(sub { Dist::Zilla::File::OnDisk->new({ name => $_ }) });
  },
);

sub plugins_with {
  my ($self, $role) = @_;

  $role =~ s/^-/Dist::Zilla::Role::/;
  my $plugins = $self->plugins->grep(sub { $_->does($role) });

  return $plugins;
}

has root => (
  is   => 'ro',
  isa  => Dir,
  coerce   => 1,
  required => 1,
);

sub prereq {
  my ($self) = @_;

  # XXX: This needs to always include the highest version. -- rjbs, 2008-06-01
  my $prereq = {};
  $prereq = $prereq->merge( $_->prereq )
    for $self->plugins_with(-FixedPrereqs)->flatten;

  return $prereq;
}

sub build_dist {
  my ($self, $arg) = @_;
  $arg ||= {};

  $_->before_build for $self->plugins_with(-BeforeBuild)->flatten;

  my $build_root = Path::Class::dir(
    $arg->{build_root} || ($self->name . '-' . $self->version)
  );

  $build_root->mkpath unless -d $build_root;

  my $dist_root = $self->root;
  
  $_->prune_files for $self->plugins_with(-FilePruner)->flatten;

  # my $dist_name = $self->name . '-' . $self->version;
  # my $target = $build_root->subdir($dist_name);
  # $target->rmtree if -d $target;
  $build_root->rmtree if -d $build_root;

  for ($self->plugins_with(-FileWriter)->flatten) {
    my $new_files = $_->write_files({
      build_root => $build_root,
    });

    $self->files->push($new_files->flatten);
  }

  for my $file ($self->files->flatten) {
    $_->munge_file($file) for $self->plugins_with(-FileMunger)->flatten;

    my $file_path = Path::Class::file($file->name);

    my $to_dir = $build_root->subdir( $file_path->dir );
    my $to = $to_dir->file( $file_path->basename );
    $to_dir->mkpath unless -e $to_dir;
    die "not a directory: $to_dir" unless -d $to_dir;
  
    Carp::croak("attempted to write $to multiple times") if -e $to;

    open my $out_fh, '>', "$to" or die "couldn't open $to to write: $!";
    print { $out_fh } $file->content;
    close $out_fh or die "error closing $to: $!";
  }

  for ($self->plugins_with(-AfterBuild)->flatten) {
    $_->after_build({ build_root => $build_root });
  }

  return unless $arg->{build_tarball};

  require Archive::Tar;
  my $archive = Archive::Tar->new;
  $archive->add_files( File::Find::Rule->file->in($build_root) );
  $archive->write(
    $self->name . '-' . $self->version . '.tar.gz',
    9, ## no critic
  );

  $build_root->rmtree;
}

# XXX: yeah, uh, do something more awesome -- rjbs, 2008-06-01
sub log { ## no critic
  my ($self, $msg) = @_;
  print "$msg\n";
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;
__END__
=head1 DESCRIPTION

Dist::Zilla builds distributions of code to be uploaded to the CPAN.  In this
respect, it is like L<ExtUtils::MakeMaker>, L<Module::Build>, or
L<Module::Install>.  Unlike those tools, however, it is not also a system for
installing code that has been downloaded from the CPAN.  Since it's only run by
authors, and is meant to be run on a repository checkout rather than on
published, released code, it can do much more than those tools, and is free to
make much more ludicrous demands in terms of prerequisites.

