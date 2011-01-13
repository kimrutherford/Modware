package Modware::Export::Command::dictypub;
use strict;

# Other modules:
use namespace::autoclean;
use Moose;
use Bio::Chado::Schema;
use Try::Tiny;
use File::Spec::Functions;
use Spreadsheet::WriteExcel;
extends qw/Modware::Export::Command/;
with 'Modware::Role::Command::WithEmail';
with 'Modware::Role::Command::WithLogger';

# Module implementation
#

has '+input'    => ( traits => [qw/NoGetopt/] );
has '+data_dir' => ( traits => [qw/NoGetopt/] );

has 'topic2file' => (
    is      => 'ro',
    isa     => 'HashRef',
    traits  => [qw/Hash NoGetopt/],
    default => sub {
        return {
            'Genome-wide Analysis' => 'High_throughput_papers',
            'Reviews'              => 'Reviews.txt',
            'Reviews:Genome-wide Analysis' =>
                'not_reviews_not_high_throughput_papers.txt',
        };
    },
    handles => {
        topics       => 'keys',
        get_filename => 'get'
    }
);

has 'base_query' => (
    is      => 'rw',
    isa     => 'HashRef',
    traits  => [qw/Hash NoGetopt/],
    default => sub {
        { 'cvterm.name' => 'dictyBase_literature_topic' };
    },
    handles => {
        add_query       => 'set',
        get_query_value => 'get',
    }
);

has 'chado' => (
    is      => 'rw',
    isa     => 'Bio::Chado::Schema',
    lazy    => 1,
    builder => '_build_chado',
);

has 'spreadsheet' => (
    is       => 'rw',
    isa      => 'Bool',
    default  => 1,
    cmd_flag => 'xls',
    traits   => [qw/Getopt/],
    documentation =>
        'Dumping the output in spreadsheet format,  default is on'
);

sub _build_chado {
    my ($self) = @_;
    my $schema = Bio::Chado::Schema->connect( $self->dsn, $self->user,
        $self->password, $self->attribute );
    my $source     = $schema->source('Sequence::Feature');
    my $class_name = 'Bio::Chado::Schema::' . $source->source_name;
    $source->add_column(
        'is_deleted' => {
            data_type     => 'boolean',
            is_nullable   => 0,
            default_value => 'false'
        }
    );
    $class_name->add_column(
        'is_deleted' => {
            data_type     => 'boolean',
            is_nullable   => 0,
            default_value => 'false'
        }
    );
    $class_name->register_column(
        'is_deleted' => {
            data_type     => 'boolean',
            is_nullable   => 0,
            default_value => 'false'
        }
    );

}

sub execute {
    my $self   = shift;
    my $log    = $self->dual_logger;
    my $bcs    = $self->chado;
    my $output = $self->output_handler;
    $self->subject('Pubmed export robot');    # -- email subject
    my ( $sp, $ws, $row );
    if ( $self->spreadsheet ) {
        $row = 0;
        $spreadsheet
            = Spreadsheet::WriteExcel->new( $self->get_spreadsheet_name );
        $ws = $spreadsheet->add_worksheet;
        $ws->write_row( $row++, 0,
            [ 'pubmed', 'gene_name', 'dictyBase id' ] );
    }

    my $rs = $bcs->resultset('Sequence::FeatureCvterm')->search(
        {   'feature.is_deleted' => 0,
            'type.name'          => 'gene',
            'pub.pubplace'       => 'PUBMED'
        },
        { join => [ { 'feature' => 'type' }, 'pub' ], cache => 1, }
    );
    $self->set_total_count( $rs->count );

PUB:
    while ( my $row = $rs->next ) {
        my $pubmed_id = $row->pub->uniquename;
        if ( $pubmed_id =~ /^PUB/ ) {
            $log->error( 'Not pubmed id in my book for ', $row->pub->pub_id );
            $self->inc_error;
            next PUB;
        }
        my $feature   = $row->feature;
        my $gene_id   = $feature->dbxref->accession;
        my $gene_name = $feature->name;
        my $ddb_id    = $self->gene2ddb($gene_id);
        $output->print( sprintf "%s\t%s\t%s\n", $pubmed_id, $name, $ddb_id );
        if ( $self->spreadsheet ) {
            $ws->write_row( $row++, 0, [ $pubmed_id, $name, $ddb_id ] );
        }
        $self->inc_process;
    }

    $log->info( sprintf "total:%i\tprocess:%i\tfailed:%i\n",
        $self->total_count, $self->process_count, $self->error_count );

    for my $name ( $self->topics ) {
        if ( $name =~ /:/ ) {
            my ( $param1, $param2 ) = split /:/, $name;
            $self->add_query( 'cvterm.name' => { '!=', $param1 } );
            $self->add_query( 'cvterm.name' => { '!=', $param2 } );
        }
        else {
            $self->add_query( 'cvterm.name' => $name );
        }
        my $topic_rs = $rs->search( $self->base_query,
            { join => { 'feature_pubprops' => { 'type' => 'cv' } } } );
        $self->export_with_topic( $topic_rs, $self->get_filename($name) );
    }
}

sub export_with_topic {
    my ( $self, $rs, $file );
    my $filehandle = Path::Class::File->new($file)->openw;
    while ( my $row = $rs->next ) {
        my $cvterm_rs = $row->feature_pubprops->search_related(
            'type',
            { 'cv.name' => 'dictyBase_literature_topic' },
            { join      => 'cv' }
        );
        my $topic_string = join( ', ', map { $_->name } $cvterm_rs->all );
        $filehandle->print( $row->feature->dbxref->accession,
            "\t", $row->pub->uniquename, "\t$topic_string\n" );
    }
    $filehandle->close;
}

sub get_spreadsheet_name {
    my ($self) = @_;
    my $name = ( ( split /\./, $self->output->basename ) )[0];
    return catfile( $self->output->dir->stringify, $name . '.xls' );
}

sub gene2ddb {
    my ( $self, $gene_id ) = @_;
    my $schema = $self->chado;
    my $rs
        = $schema->resultset('Sequence::Feature')
        ->search( { 'dbxref.accession' => $gene_id }, { join => 'dbxref' } )
        ->search_related(
        'feature_relationship_objects',
        { 'type.name' => 'part_of' },
        { join        => 'type' }
        )->search_related(
        'subject',
        {   'type_2.name' => [ -or => { -like => '%RNA' }, 'pseudogene' ],
            'dbxref_2.accession' => [
                'Sequencing Center',
                { -like => '%RNA%' },
                { -like => '%Curator%' },
                { -like => '%Soderbom%' }
            ]
        },
        {   join     => [ 'type', { 'feature_dbxrefs' => 'dbxref' } ],
            prefetch => 'dbxref',
            select => [ 'dbxref_3.accession', 'dbxref_2.accession' ],
            as     => [qw/id source/]
        }
        );

    my $count = $rs->count;
    if ( $count == 1 ) {
        return $rs->first->dbxref->accession;
    }
    my @id = map { $_->get_column('id') }
        grep { $_->get_column('source') eq 'dictyBase Curator' } $rs->all;
    my @id = map { $_->get_column('id') } $rs->all
        if !@id;
    return $id[0];

}

1;    # Magic true value required at end of module

__END__

=head1 NAME

Update full text url of pubmed records in dicty chado database
