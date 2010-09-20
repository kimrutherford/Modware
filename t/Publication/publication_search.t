use Test::More qw/no_plan/;
use aliased 'Modware::DataSource::Chado';
use Modware::Build;

BEGIN {
    use_ok('Modware::Chado::Query::BCS::Publication::Pubmed');
}

my $build = Modware::Build->current;
Chado->connect(
    dsn      => $build->config_data('dsn'),
    user     => $build->config_data('user'),
    password => $build->config_data('password')
);

my $Pub = 'Modware::Chado::Query::BCS::Publication::Pubmed';
my $itr = $Pub->search( author => 'Ian' );
isa_ok( $itr, 'Modware::Collection::Iterator::BCS::ResultSet' );
is( $itr->count, 3, 'it can search publications with author name' );
is( $Pub->count( author => 'Ian' ),
    3, 'it can search no of publications by an author' );
is( $Pub->count( journal => 'PloS' ),
    2, 'it can count publications by journal name' );

my $pub = $Pub->find_by_pubmed_id(20830294);
isa_ok($pub,  'Modware::Publication');

my $pub2 = $Pub->find($pub->dbrow->pub_id);
isa_ok($pub2,  'Modware::Publication');

is( $Pub->search( last_name => 'Lewin', first_name => 'AS Alfred S' )
        ->count, 1, 'has publication from first and last name search'
);