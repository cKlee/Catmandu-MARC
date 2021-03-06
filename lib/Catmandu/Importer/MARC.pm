package Catmandu::Importer::MARC;
use Catmandu::Sane;
use Catmandu::Util;
use Moo;

our $VERSION = '1.05';

has type           => (is => 'ro' , default => sub { 'ISO' });
has _importer      => (is => 'ro' , lazy => 1 , builder => '_build_importer' , handles => ['generator']);
has _importer_args => (is => 'rwp', writer => '_set_importer_args');

with 'Catmandu::Importer';

sub _build_importer {
    my ($self) = @_;

    my $type = $self->type;

    $type = 'Record' if exists $self->_importer_args->{records};

    my $pkg = Catmandu::Util::require_package($type,'Catmandu::Importer::MARC');

    $pkg->new($self->_importer_args);
}

sub BUILD {
    my ($self,$args) = @_;
    $self->_set_importer_args($args);

    # keep USMARC temporary as alias for ISO, remove in future version
    # print deprecation warning
    if ($self->{type} eq 'USMARC') {
        $self->{type} = 'ISO';
        warn( "deprecated", "Oops! Importer \"USMARC\" is deprecated. Use \"ISO\" instead." );
    }
}

1;
__END__

=head1 NAME

Catmandu::Importer::MARC - Package that imports MARC data

=head1 SYNOPSIS

    use Catmandu -all;

    # import records from file
    my $importer = Catmandu->importer('MARC',file => '/foo/bar.mrc');

    my $count = $importer->each(sub {
        my $record = shift;
        # ...
    });

    # import records and apply a fixer
    my $fixer = fixer("marc_map('245a','title')");

    $fixer->fix($importer)->each(sub {
        my $record = shift;
        printf "title: %s\n" , $record->{title};
    });

Convert MARC to JSON mapping 245a to a title with the L<catmandu> command line client:

    catmandu convert MARC --fix "marc_map('245a','title')" < /foo/bar.mrc

=head1 DESCRIPTION

Catmandu::Importer::MARC is a L<Catmandu::Importer> to import MARC records from an
external source. Each record is imported as HASH containing two keys:

=over

=item C<_id>

the system identifier of the record (usually the 001 field)

=item C<record>

an ARRAY of ARRAYs containing the record data

=back

=head2 EXAMPLE ITEM

 {
    record => [
      [
        '001',
        undef,
        undef,
        '_',
        'fol05882032 '
      ],
      [
        '245',
        '1',
        '0',
        'a',
        'Cross-platform Perl /',
        'c',
        'Eric F. Johnson.'
      ],
    ],
    _id' => 'fol05882032'
 }

=head1 METHODS

This module inherits all methods of L<Catmandu::Importer> and by this
L<Catmandu::Iterable>.

=head1 CONFIGURATION

In addition to the configuration provided by L<Catmandu::Importer> (C<file>,
C<fh>, etc.) the importer can be configured with the following parameters:

=over

=item type

Describes the MARC syntax variant. Supported values include:

=over

=item * ISO: L<Catmandu::Importer::MARC::ISO> (default)

=item * MicroLIF: L<Catmandu::Importer::MARC::MicroLIF>

=item * MARCMaker: L<Catmandu::Importer::MARC::MARCMaker>

=item * MiJ: L<Catmandu::Importer::MARC::MiJ> (MARC in JSON)

=item * XML: L<Catmandu::Importer::MARC::XML>

=item * RAW: L<Catmandu::Importer::MARC::RAW>

=item * Lint: L<Catmandu::Importer::MARC::Lint>

=item * ALEPHSEQ: L<Catmandu::Importer::MARC::ALEPHSEQ>

=back

=head1 SEE ALSO

L<Catmandu::Exporter::MARC>

=cut
