#!/usr/bin/perl -w

package Logger;
use Log::Log4perl;
use Log::Log4perl::Appender;
use Log::Log4perl::Level;

sub handler {
    my ( $class, $file ) = @_;

    my $appender;
    if ($file) {
        $appender = Log::Log4perl::Appender->new(
            'Log::Log4perl::Appender::File',
            filename => $file,
            mode     => 'clobber'
        );
    }
    else {
        $appender
            = Log::Log4perl::Appender->new(
            'Log::Log4perl::Appender::ScreenColoredLevels',
            );
    }

    my $layout = Log::Log4perl::Layout::PatternLayout->new(
        "[%d{MM-dd-yyyy hh:mm}] %p - %m%n");

    my $log = Log::Log4perl->get_logger();
    $appender->layout($layout);
    $log->add_appender($appender);
    $log->level($DEBUG);
    $log;
}

1;

package GAFHelper;
use namespace::autoclean;
use Moose;
use MooseX::Params::Validate;

has 'chado' => (
    is  => 'rw',
    isa => 'Bio::Chado::Schema'
);

has 'dbrow' => (
    is      => 'rw',
    isa     => 'HashRef',
    traits  => [qw/Hash/],
    default => sub { {} },
    handles => {
        add_dbrow    => 'set',
        get_dbrow    => 'get',
        delete_dbrow => 'delete',
        has_dbrow    => 'defined'
    }
);

sub find_dbxref_id {
    my ( $self, $dbxref, $db ) = validated_list(
        \@_,
        dbxref => { isa => 'Str' },
        db     => { isa => 'Str' },
    );

    my $rs = $self->chado->resultset('General::Dbxref')->search(
        {   accession => $dbxref,
            db_id     => $db
        }
    );
    if ( $rs->count ) {
        return $rs->first->dbxref_id;
    }
}

sub has_idspace {
    my ( $self, $id ) = @_;
    return 1 if $id =~ /:/;
}

sub parse_id {
    my ( $self, $id ) = @_;
    return split /:/, $id;
}

sub parse_evcode {
    my $self = shift;
    my ($anno) = pos_validated_list( \@_, { isa => 'GOBO::Annotation' } );
    my ($evcode) = ( ( split /\-/, $anno->evidence ) )[0];
    $evcode;
}

__PACKAGE__->meta->make_immutable;

1;

package GAFManager;
use namespace::autoclean;
use Moose;
use Carp;
use Data::Dumper::Concise;
use Moose::Util qw/ensure_all_roles/;

has 'helper' => (
    is      => 'rw',
    isa     => 'GAFHelper',
    trigger => sub {
        my ( $self, $helper ) = @_;
        my $chado = $helper->chado;
        $self->meta->make_mutable;
        my $engine = 'GAFEngine::' . ucfirst lc( $chado->storage->sqlt_type );
        ensure_all_roles( $self, $engine );
        $self->meta->make_immutable;
        $self->setup;
        $self->meta->make_immutable;
        $self->_preload_evcode_cache;
    }
);

has 'target' => (
    is        => 'rw',
    isa       => 'GOBO::Node',
    clearer   => 'clear_target',
    predicate => 'has_target'
);

has 'gene' => (
    is        => 'rw',
    isa       => 'GOBO::Gene',
    clearer   => 'clear_gene',
    predicate => 'has_gene'
);

has 'annotation' => (
    is        => 'rw',
    isa       => 'GOBO::Annotation',
    clearer   => 'clear_annotation',
    predicate => 'has_annotation'
);

has 'feature_row' => (
    is        => 'rw',
    isa       => 'Bio::Chado::Schema::Sequenece::FeatureCvterm',
    predicate => 'has_feature_row'
);

has 'cvterm_row' => (
    is        => 'rw',
    isa       => 'Bio::Chado::Schema::Cv:Cvterm',
    predicate => 'has_cvterm_row'
);

has 'graph' => (
    is  => 'rw',
    isa => 'GOBO::Graph'
);

has 'cache' => (
    is      => 'rw',
    isa     => 'ArrayRef',
    traits  => [qw/Array/],
    default => sub { [] },
    handles => {
        add_to_cache     => 'push',
        clean_cache      => 'clear',
        entries_in_cache => 'count',
        cache_entries    => 'elements'
    }
);

has 'term_cache' => (
    is      => 'rw',
    isa     => 'HashRef',
    traits  => [qw/Hash/],
    default => sub { {} },
    handles => {
        add_to_term_cache   => 'set',
        clean_term_cache    => 'clear',
        terms_in_cache      => 'count',
        terms_from_cache    => 'keys',
        is_term_in_cache    => 'defined',
        get_term_from_cache => 'get'
    }
);

has 'evcode_cache' => (
    is      => 'rw',
    isa     => 'HashRef',
    traits  => [qw/Hash/],
    default => sub { {} },
    handles => {
        add_to_evcode_cache   => 'set',
        clean_evcode_cache    => 'clear',
        evcodes_in_cache      => 'count',
        evcodes_from_cache    => 'keys',
        has_evcode_in_cache   => 'defined',
        get_evcode_from_cache => 'get'
    }
);

has 'skipped_message' => (
    is      => 'rw',
    isa     => 'Str',
    clearer => 'clear_message'
);

sub find_annotated {
    my ($self) = @_;
    my $anno   = $self->annotation;
    my $gene   = $anno->gene;
    $self->gene($gene);

    my $id = $gene->id;
    if ( $self->helper->has_idspace($id) ) {
        my @data = $self->helper->parse_id($id);
        $id = $data[1];
    }
    my $rs
        = $self->helper->chado->resultset('Sequence::Feature')
        ->search(
        { -or => [ 'uniquename' => $id, 'dbxref.accession' => $id ], },
        { join => 'dbxref', cache => 1 } );

    if ( !$rs->count ) {
        $self->skipped_message( 'DB object id ', $gene->id, ' not found' );
        return;
    }
    if ( $rs->count > 1 ) {
        $self->skipped_message(
            'Multiple object ids ',
            join( ' - ', map { $_->uniquename } $rs->all ),
            ' is mapped to ', $gene->id
        );
        return;
    }
    $self->feature_row( $rs->first );
    $rs->fist->feature_id;
}

sub find_term {
    my ($self) = @_;
    my $anno   = $self->annotation;
    my $target = $anno->target;
    $self->target($target);

    my ( $db, $id ) = $self->helper->parse_id( $target->id );
    my $rs = $self->helper->chado->resultset('Cv::Cvterm')->search(
        {   'db.name'          => $db,
            'dbxref.accession' => $id,
            'cv.name'          => $target->namespace
        },
        { join => [ 'cv', { 'dbxref' => 'db' } ] }
    );

    if ( !$rs->count ) {
        $self->skipped_message("GO id $id not found");
        return;
    }

    if ( $rs->count > 1 ) {
        $self->skipped_message(
            'Multiple GO ids ',
            join( ' - ', map { $_->dbxref->accession } $rs->all ),
            ' is mapped to ', $id
        );
        return;
    }
    $self->target_row( $rs->first );
    $rs->first->cvterm_id;

}

sub check_for_evcode {
    my ( $self, $anno ) = @_;
    $anno ||= $self->annotation;
    my $evcode = $self->helper->parse_evcode;
    return 1 if $self->has_evcode_in_cache($evcode);
    $self->skipped_message("$evcode not found");
    return 0;
}

sub find_annotation {
    my ($self)      = @_;
    my $anno        = $self->annotation;
    my $feature_row = $self->feature_row;
    my $target_row  = $self->target_row;
    my $evcode      = $self->parse_evcode($anno);
    my $evcode_id = $self->get_evcode_from_cache($evcode)->cvterm->cvterm_id;

    my $rs
        = $self->helper->chado->resultset('Sequence::FeatureCvterm')->search(
        {   feature_id                    => $feature_row->feature_id,
            cvterm_id                     => $target_row->cvterm_id,
            'feature_cvtermprops.type_id' => $evcode_id,
        },
        { join => 'feature_cvtermprops', cache => 1 }
        );

    if ( !$rs->count ) {
        $self->skipped_message( "No existing annotation for ",
            $self->gene->id, ' and ', $self->target->id );
        return;
    }
    return $rs->first;
}

sub keep_state_in_cache {
    my ($self) = @_;
    $self->add_to_cache( $self->insert_hashref );
}

sub clear_current_state {
    my ($self) = @_;
    $self->clear_stashes;
    $self->clear_node;
}

__PACKAGE__->meta->make_immutable;

1;

package GAFEngine::Oracle;
use namespace::autoclean;
use Bio::Chado::Schema;
use Moose::Role;

sub setup {
    my $self       = shift;
    my $source     = $self->helper->chado->source('Cv::Cvtermsynonym');
    my $class_name = 'Bio::Chado::Schema::' . $source->source_name;
    $source->remove_column('synonym');
    $source->add_column(
        'synonym_' => {
            data_type   => 'varchar',
            is_nullable => 0,
            size        => 1024
        }
    );
    $class_name->add_column(
        'synonym_' => {
            data_type   => 'varchar',
            is_nullable => 0,
            size        => 1024
        }
    );
    $class_name->register_column(
        'synonym_' => {
            data_type   => 'varchar',
            is_nullable => 0,
            size        => 1024
        }
    );

}

sub _preload_evcode_cache {
    my ($self) = @_;
    my $chado  = $self->helper->chado;
    my $rs     = $chado->resultset('Cv::Cv')
        ->search( { 'name' => { -like => 'evidence_code%' } } );
    return if !$rs->count;

    my $syn_rs = $rs->cvterms->search_related(
        'cvtermsynonyms_cvterms',
        {   'type.name' => { -in => [qw/EXACT RELATED/] },
            'cv.name'   => 'synonym_type'
        },
        { join => [ { 'type' => 'cv' } ] }
    );
    $self->add_to_ecode_cache( $_->_synonym, $_ ) for $syn_rs->all;
}

1;

package GAFEngine::Postgresql;
use namespace::autoclean;
use Moose::Role;

sub setup {
}

sub _preload_ecode_cache {
    my ($self) = @_;
    my $chado  = $self->helper->chado;
    my $rs     = $chado->resultset('Cv::Cv')
        ->search( { 'name' => { -like => 'evidence_code%' } } );
    return if !$rs->count;

    my $syn_rs = $rs->cvterms->search_related(
        'cvtermsynonyms_cvterms',
        {   'type.name' => { -in => [qw/EXACT RELATED/] },
            'cv.name'   => 'synonym_type'
        },
        { join => [ { 'type' => 'cv' } ] }
    );
    $self->add_to_ecode_cache( $_->synonym, $_ ) for $syn_rs->all;
}

1;

package GAFLoader;
use namespace::autoclean;
use Moose;
use Try::Tiny;
use Carp;
use Data::Dumper::Concise;
use List::MoreUtils qw/uniq/;
use Set::Object;

has 'manager' => (
    is  => 'rw',
    isa => 'GAFManager'
);

has 'helper' => (
    is  => 'rw',
    isa => 'GAFHelper'
);

has 'resultset' => (
    is  => 'rw',
    isa => 'Str'
);

sub store_cache {
    my ( $self, $cache ) = @_;
    my $chado = $self->manager->helper->chado;
    my $index;
    try {
        $chado->txn_do(
            sub {

                #$chado->resultset( $self->resultset )->populate($cache);
                for my $i ( 0 .. scalar @$cache - 1 ) {
                    $index = $i;
                    $chado->resultset( $self->resultset )
                        ->create( $cache->[$i] );
                }
            }
        );
    }
    catch {
        warn "error in creating: $_";
        croak Dumper $cache->[$index];
    };
}

sub update {
    my $self = shift;
    my ($row)
        = pos_validated_list( \@_,
        { isa => 'Bio::Chado::Schema::Sequenece::FeatureCvterm' } );

    my $anno = $self->manager->annotation;

    #compare and update qualifier(s) if any
    my $neg_flag = $anno->negated ? 1 : 0;
    $row->update( { is_not => $neg_flag } ) if $neg_flag ne $row->is_not;

    #check for references
    # -- anything that has PMID considered literature reference
    # -- rest of them considered database records in chado feature table
    if (    $self->helper->is_from_pubmed( $anno->provenance->id )
        and $row->pubmed_id )
    { #there is pubmed_id in both places,  lets check and see if they need update
        my $pubmed_id = $self->helper->parse_id( $anno->provenace->id );
        if ( $pubmed_id ne $row->pub->uniquename ) {    #-- needs update
            if ( $db_id
                = $self->helper->chado->resultset('Pub::Pub')
                ->find( { uniquename => $pubmed_id } ) )
            {
                $row->update( { pub_id => $db_id } );
            }
            else {
                $self->manager->skipped_message( 'Could not find reference ',
                    $anno->provenance->id );
                return;
            }
        }
    }
    else {
        my ( $db, $id ) = $self->helper->parse_id( $anno->provenance->id );
        my $cvt_dbxref_rs = $row->feature_cvterm_dbxrefs;
        if ( !first_value { $id eq $_->dbxref->accession }
            $cvt_dbxref_rs->all )
        {    ## - needs update
            my $dbxref_rs = $self->helper->chado->resultset('General::Dbxref')
                ->search( { accession => $id }, { cache => 1 } );
            if ( $dbxref_rs->count ) {
                $row->update_or_create_related( 'feature_cvterm_dbxrefs',
                    { dbxref_id => $dbxref_rs->first->dbxref_id } );
            }
            else {
                $self->manager->skipped_message( 'Could not find reference ',
                    $anno->provenance->id );
                return;
            }
        }
    }

    my $anno_rec
        = Set::Object->new( $self->helper->get_anno_db_records($anno) );
    my $anno_pub
        = Set::Object->new( $self->helper->get_anno_pub_records($anno) );

    my $db_rec = Set::Object->new( $self->helper->db_records($row) );
    my $db_pub = Set::Object->new( $self->helper->db_pub_records($row) );

    ## -- removing reference
    for my $db_id ( $db_rec->difference($anno_rec)->elements )
    {    ## -- database reference removed from annotation
        my $rs = $self->helper->chado->resultset('General::Dbxref')
            ->search( { accession => $db_id }, { cache => 1 } );

        if ( $rs->count ) {
            $row->feature_cvterm_dbxrefs(
                { dbxref_id => $rs->first->dbxref_id } )->delete_all;
        }
    }

    for my $pub_id ( $db_pub->difference($anno_pub)->elements )
    {    ## -- database pubmed removed from annotation
        my $rs = $self->helper->chado->resultset('Pub::Pub')
            ->find( { uniquename => $pub_id }, { cache => 1 } );
        if ($rs) {
            $row->feature_cvterm_pubs( { pub_id => $rs->pub_id } )
                ->delete_all;
        }
    }

    ## -- adding reference with database id
    for my $anno_id ( $anno_rec->difference($db_rec)->elements )
    {    ## -- database reference removed from annotation
        my $rs = $self->helper->chado->resultset('General::Dbxref')
            ->search( { accession => $anno_id }, { cache => 1 } );
        if ( $rs->count ) {
            $row->create_related( 'feature_cvterm_dbxrefs',
                { dbxref_id => $rs->first->dbxref_id } );
        }
        else {
            warn "$db_id not found: no link created\n";
        }
    }

	## -- adding reference with publication id
    for my $anno_pub_id ( $anno_pub->difference($db_pub)->elements )
    {    ## -- database pubmed removed from annotation
        my $rs = $self->helper->chado->resultset('Pub::Pub')
            ->find( { uniquename => $anno_pub_id }, { cache => 1 } );
        if ($rs) {
            $row->add_to_feature_cvterm_pubs( { pub_id => $rs->pub_id } );
        }
        else {
            warn "$anno_pub_id not found: no link created\n";
        }
    }

    ## -- Still don't know where to model *With colum 8* and *Qualifier column 4* other
    ## -- than NOT value.
    ## -- Still don't know where to store *Date column 14* and *Assigned by column 15*
}

__PACKAGE__->meta->make_immutable;

1;

package main;

use strict;
use Pod::Usage;
use Getopt::Long;
use YAML qw/LoadFile/;
use Bio::Chado::Schema;
use GOBO::Parsers::GAFParser;
use Data::Dumper::Concise;
use Carp;
use Try::Tiny;

my ( $dsn, $user, $password, $config, $log_file, $logger );
my $commit_threshold = 1000;
my $attr = { AutoCommit => 1 };

GetOptions(
    'h|help'                => sub { pod2usage(1); },
    'u|user:s'              => \$user,
    'p|pass|password:s'     => \$password,
    'dsn:s'                 => \$dsn,
    'c|config:s'            => \$config,
    'l|log:s'               => \$log_file,
    'ct|commit_threshold:s' => \$commit_threshold,
    'a|attr:s%{1,}'         => \$attr
);

pod2usage("!! gaf input file is not given !!") if !$ARGV[0];

if ($config) {
    my $str = LoadFile($config);
    pod2usage("given config file $config do not have database section")
        if not defined $str->{database};

    pod2usage("given config file $config do not have dsn section")
        if not defined $str->{database}->{dsn};

    $dsn      = $str->{database}->{dsn};
    $user     = $str->{database}->{dsn} || undef;
    $password = $str->{database}->{dsn} || undef;
    $attr     = $str->{database}->{attr} || $attr;
    $logger
        = $str->{log}
        ? Logger->handler( $str->{log} )
        : Logger->handler;

}
else {
    pod2usage("!!! dsn option is missing !!!") if !$dsn;
    $logger = $log_file ? Logger->handler($log_file) : Logger->handler;
}

my $schema = Bio::Chado::Schema->connect( $dsn, $user, $password, $attr );

my $helper = GAFHelper->new( chado => $schema );
my $manager = GAFManager->new( helper => $helper );
my $loader = GAFLoader->new( manager => $manager );
$loader->helper($helper);
$loader->resultset('Feature::Cvterm');

# -- evidence ontology loaded
if ( !$manager->evcodes_in_cache ) {
    warn '!! Evidence codes ontology needed to be loaded !!!!';
    die
        'Download it from here: http://www.obofoundry.org/cgi-bin/detail.cgi?id=evidence_code';
}

$logger->info("parsing gaf file ....");
my $parser = GOBO::Parsers::GAFParser->new( file => $ARGV[0] );
$parser->parse;
my $graph = $parser->graph;
$logger->info("parsing done ....");

$manager->graph($graph);

my $skipped = 0;
my $loaded  = 0;
my $updated = 0;

#### -- Relations/Typedef -------- ##
my $all_anno   = $graph->annotations;
my $anno_count = scalar @$all_anno;
$logger->info("Got $anno_count annotations ....");

ANNOTATION:
for my $anno (@$all_anno) {
    $manager->annotation($anno);
    if (    !$manager->find_annotated
        and !$manager->find_term
        and !$manager->check_for_evcode )
    {

        # -- check the annotated entry and node
        $log->warn( $self->skipped_message );
        $skipped++;
        next ANNOTATION;
    }

    if ( my $result = $manager->find_annotations )
    {    # -- annotation is present
        $loader->update($result);
        $log->info(
            $anno->gene->id, ' and ', $anno->term->id,
            ' been updated with ',
            join( "\t", $manager->update_tags ), "\n"
        );
        $updated++;
        next ANNOTATION;
    }
}

#process for new entries
$manager->process;
$manager->keep_state_in_cache;
$manager->clear_current_state;

if ( $manager->entries_in_cache >= $commit_threshold ) {
    my $entries = $manager->entries_in_cache;

    $logger->info("going to load $entries annotations ....");

    #$dumper->print( Dumper $onto_manager->cache );
    $loader->store_cache( $manager->cache );
    $manager->clean_cache;

    $logger->info("loaded $entries annotations ....");
    $loaded += $entries;
    $logger->info(
        "Going to process ",
        $anno_count - $loaded,
        " annotations"
    );
}
}

if ( $manager->entries_in_cache ) {
    my $entries = $manager->entries_in_cache;
    $logger->info("going to load leftover $entries annotations ....");
    $loader->store_cache( $onto_manager->cache );
    $onto_manager->clean_cache;
    $logger->info("loaded leftover $entries annotations ....");
    $loaded += $entries;
}

$logger->info(
    "Annotations >> Processed:$anno_count Updated:$updated  New:$loaded");

=head1 NAME


B<gaf2chado.pl> - [Loads gaf annotations in chado database]


=head1 SYNOPSIS

perl gaf2chado.pl [options] <gaf file>

perl gaf2chado.pl --dsn "dbi:Pg:dbname=gmod" -u tucker -p halo myanno.gaf

perl gaf2chado.pl --dsn "dbi:Oracle:sid=modbase;host=localhost" -u tucker -p halo mgi.gaf

perl gaf2chado.pl -c config.yaml -l output.txt dicty.gaf


=head1 REQUIRED ARGUMENTS

gaf file                 gaf annotation file

=head1 OPTIONS

-h,--help                display this documentation.

--dsn                    dsn of the chado database

-u,--user                chado database user name

-p,--pass,--password     chado database password 

-l,--log                 log file for writing output,  otherwise would go to STDOUT 

-a,--attr                Additonal attribute(s) for database connection passed in key value pair 

-ct,--commit-threshold   No of entries that will be cached before it is commited to
                         storage, default is 1000

-c,--config              yaml config file,  if given would take preference

=head2 Yaml config file format

database:
  dsn:'....'
  user:'...'
  password:'.....'
log: '...'



=head1 DESCRIPTION

The loader assumes the annotated entries(refered in column 1-3, 10, 11 and 12) and
reference(column 6) are already present in the database. 


=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

Modware

GO::Parsers

=head1 BUGS AND LIMITATIONS

No bugs have been reported.Please report any bugs or feature requests to

B<Siddhartha Basu>


=head1 AUTHOR

I<Siddhartha Basu>  B<siddhartha-basu@northwestern.edu>

=head1 LICENCE AND COPYRIGHT

Copyright (c) B<2010>, Siddhartha Basu C<<siddhartha-basu@northwestern.edu>>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.



