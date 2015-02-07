package App::ModuleBuildTiny;

use 5.010;
use strict;
use warnings FATAL => 'all';
our $VERSION = '0.005';

use Exporter 5.57 'import';
our @EXPORT = qw/modulebuildtiny/;

use Carp qw/croak/;
use Config;
use CPAN::Meta;
use ExtUtils::Manifest qw/manifind maniskip maniread/;
use File::Basename qw/basename dirname/;
use File::Copy qw/copy/;
use File::Path qw/mkpath rmtree/;
use File::Slurper qw/write_text/;
use File::Spec::Functions qw/catfile rel2abs/;
use Getopt::Long 2.36 'GetOptionsFromArray';

sub prereqs_for {
	my ($meta, $phase, $type, $module, $default) = @_;
	return $meta->effective_prereqs->requirements_for($phase, $type)->requirements_for_module($module) || $default || 0;
}

sub get_files {
	my %opts = @_;
	my $files;
	if (not $opts{regenerate}{MANIFEST} and -r 'MANIFEST') {
		$files = maniread;
	}
	else {
		my $maniskip = maniskip;
		$files = manifind();
		delete $files->{$_} for keys %{ $opts{regenerate} }, grep { $maniskip->($_) } keys %$files;
	}
	
	$files->{'Build.PL'} //= do {
		my $minimum_mbt  = prereqs_for($opts{meta}, qw/configure requires Module::Build::Tiny/);
		my $minimum_perl = prereqs_for($opts{meta}, qw/runtime requires perl 5.006/);
		my $dist_name = $opts{meta}->name;
		"# This Build.PL for $dist_name was generated by mbtiny $VERSION.\nuse $minimum_perl;\nuse Module::Build::Tiny $minimum_mbt;\nBuild_PL();\n";
	};
	$files->{'META.json'} //= $opts{meta}->as_string;
	$files->{'META.yml'} //= $opts{meta}->as_string({ version => 1.4 });
	$files->{MANIFEST} //= join "\n", sort keys %$files;

	return $files;
}

sub get_meta {
	my %opts = @_;
	my $mergefile = $opts{mergefile} || (grep { -f } qw/metamerge.json metamerge.yml/)[0];
	if (not $opts{regenerate}{'META.json'} and -e 'META.json' and -M 'META.json' < -M 'cpanfile' and (not $mergefile or -M 'META.json' < -M $mergefile)) {
		return CPAN::Meta->load_file('META.json', { lazy_validation => 0 });
	}
	else {
		my $distname = basename(rel2abs('.'));
		$distname =~ s/(?:^(?:perl|p5)-|[\-\.]pm$)//x;
		my $filename = catfile('lib', split /-/, $distname) . '.pm';

		require Module::Metadata;
		my $data = Module::Metadata->new_from_file($filename, collect_pod => 1);
		my ($abstract) = $data->pod('NAME') =~ / \A \s+ \S+ \s? - \s? (.+?) \s* \z /x;
		my $authors = [ map { / \A \s* (.+?) \s* \z /x } grep { /\S/ } split /\n/, $data->pod('AUTHOR') ];
		my $version = $data->version($data->name)->stringify;

		my $prereqs = -f 'cpanfile' ? do { require Module::CPANfile; Module::CPANfile->load('cpanfile')->prereq_specs } : {};
		$prereqs->{configure}{requires}{'Module::Build::Tiny'} ||= Module::Metadata->new_from_module('Module::Build::Tiny')->version->stringify;
		$prereqs->{develop}{requires}{'App::ModuleBuildTiny'} ||= $VERSION;

		my $metahash = {
			name           => $distname,
			version        => $version,
			author         => $authors,
			abstract       => $abstract,
			dynamic_config => 0,
			license        => ['perl_5'],
			prereqs        => $prereqs,
			release_status => $version =~ /_|-TRIAL$/ ? 'testing' : 'stable',
			generated_by   => "App::ModuleBuildTiny version $VERSION",
			'meta-spec'    => {
				version    => '2',
				url        => 'http://search.cpan.org/perldoc?CPAN::Meta::Spec'
			},
		};
		if ($mergefile && -r $mergefile) {
			require Parse::CPAN::Meta;
			my $extra = Parse::CPAN::Meta->load_file($mergefile);
			require CPAN::Meta::Merge;
			$metahash = CPAN::Meta::Merge->new(default_version => '2')->merge($metahash, $extra);
		}
		$metahash->{provides} ||= Module::Metadata->provides(version => 2, dir => 'lib') if not $metahash->{no_index};
		return CPAN::Meta->create($metahash, { lazy_validation => 0 });
	}
}

my @generatable = qw/Build.PL META.json META.yml MANIFEST/;
Getopt::Long::Configure(qw/require_order pass_through gnu_compat/);

sub distdir {
	my %opts    = @_;
	my $meta    = get_meta();
	my $dir     = $opts{dir} || $meta->name . '-' . $meta->version;
	mkpath($dir, $opts{verbose}, oct '755');
	my $content = get_files(%opts, meta => $meta);
	for my $filename (keys %{$content}) {
		my $target = catfile($dir, $filename);
		mkpath(dirname($target)) if not -d dirname($target);
		if ($content->{$filename}) {
			write_text($target, $content->{$filename});
		}
		else {
			copy($filename, $target);
		}
	}
}

sub run {
	my %opts = @_;
	require File::Temp;
	my $dir  = File::Temp::tempdir(CLEANUP => 1);
	distdir(%opts, dir => $dir);
	chdir $dir;
	if ($opts{build}) {
		system $Config{perlpath}, 'Build.PL';
		system './Build', 'build';
	}
	system @{ $opts{command} };
}

my %actions = (
	dist => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, 'verbose!' => \my $verbose);
		require Archive::Tar;
		my $arch    = Archive::Tar->new;
		my $meta    = get_meta();
		my $name    = $meta->name . '-' . $meta->version;
		my $content = get_files(meta => $meta);
		for my $filename (keys %{$content}) {
			if ($content->{$filename}) {
				$arch->add_data($filename, $content->{$filename});
			}
			else {
				$arch->add_files($filename);
			}
		}
		$_->mode($_->mode & ~oct 22) for $arch->get_files;
		printf "tar czf $name.tar.gz %s\n", join ' ', keys %{$content} if ($verbose || 0) > 0;
		$arch->write("$name.tar.gz", &Archive::Tar::COMPRESS_GZIP, $name);
	},
	distdir => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, 'verbose!' => \my $verbose);
		distdir(verbose => $verbose);
	},
	test => sub {
		my @arguments = @_;
		my %opts = (author => 1);
		GetOptionsFromArray(\@arguments, \%opts, qw/release! author! automated!/);
		$ENV{ uc($_) . '_TESTING' } = 1 for grep { $opts{$_} } qw/release author automated/;
		run(command => [ './Build', 'test' ], build => 1);
	},
	run => sub {
		my @arguments = @_;
		croak "No arguments given to run" if not @arguments;
		GetOptionsFromArray(\@arguments, 'build!' => \(my $build = 1));
		run(command => \@arguments, build => $build);
	},
	shell => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, 'build!' => \my $build);
		run(command => [ $ENV{SHELL} ]);
	},
	listdeps => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, 'json' => \my $json);
		my $meta = get_meta();
		if (!$json) {
			print "$_\n" for sort map { $meta->effective_prereqs->requirements_for($_, 'requires')->required_modules } qw/configure build test runtime/;
		}
		else {
			my $hash = $meta->effective_prereqs->as_string_hash;
			require JSON::PP;
			print JSON::PP->new->ascii->pretty->encode($hash);
		}
	},
	regenerate => sub {
		my @arguments = @_;
		my %files = map { $_ => 1 } @arguments ? @arguments : qw/Build.PL META.json META.yml MANIFEST/;

		my $meta = get_meta(regenerate => \%files);
		my $content = get_files(meta => $meta, regenerate => \%files);
		for my $filename (keys %files) {
			mkpath(dirname($filename)) if not -d dirname($filename);
			write_text($filename, $content->{$filename}) if $content->{$filename};
		}
	},
);

sub modulebuildtiny {
	my ($action, @arguments) = @_;
	croak 'No action given' unless defined $action;
	my $call = $actions{$action};
	croak "No such action '$action' known\n" if not $call;
	return $call->(@arguments);
}

1;

=head1 NAME

App::ModuleBuildTiny - A standalone authoring tool for Module::Build::Tiny

=head1 VERSION

version 0.005

=head1 DESCRIPTION

App::ModuleBuildTiny contains the implementation of the L<mbtiny> tool.

=head1 FUNCTIONS

=over 4

=item * modulebuildtiny($action, @arguments)

This function runs a modulebuildtiny command. It expects at least one argument: the action. It may receive additional ARGV style options dependent on the command.

The actions are documented in the L<mbtiny> documentation.

=back

=head1 SEE ALSO

=head2 Helpers

=over 4

=item * L<scan_prereqs_cpanfile|scan_prereqs_cpanfile>

=item * L<cpan-upload|cpan-upload>

=item * L<perl-reversion|perl-reversion>

=back

=head2 Similar programs

=over 4

=item * L<Dist::Zilla|Dist::Zilla>

=item * L<Minilla|Minilla>

=back

=head1 AUTHOR

Leon Timmermans <leont@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Leon Timmermans.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

=begin Pod::Coverage

write_file
get_meta
dispatch
get_files
prereqs_for

=end Pod::Coverage

