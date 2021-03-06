package Catmandu::Fix::marc_spec;

use Moo;
use Catmandu::Sane;
use Catmandu::Util qw(:data :array);
use Catmandu::Fix::Has;
use MARC::Spec;
use Const::Fast;

our $VERSION = '1.05';

has spec   => ( fix_arg => 1 );
has path   => ( fix_arg => 1 );
has record => ( fix_opt => 1 );
has split  => ( fix_opt => 1 );
has join   => ( fix_opt => 1 );
has value  => ( fix_opt => 1 );
has pluck  => ( fix_opt => 1 );
has invert => ( fix_opt => 1 );

const my $NO_LENGTH            => -1;
const my $FIELD_OFFSET         => 3;
const my $INVERT_LEVEL_DEFAULT => 4;
const my $INVERT_LEVEL_3       => 3;
const my $INVERT_LEVEL_2       => 2;
const my $INVERT_LEVEL_1       => 1;
const my $INVERT_LEVEL_0       => 0;
const my $EMPTY                => q{};

my $cache;

sub fix {
    my ( $self, $data ) = @_;
    my $join_char       = $self->join // $EMPTY;
    my $record_key      = $self->record // 'record';
    my $_id             = $data->{_id};
    my ( $path, $key )  = parse_data_path( $self->path );

    # get MARCspec
    if ( !defined $cache->{ $self->spec } ) {
        $cache->{ $self->spec } = MARC::Spec->parse( $self->spec );
    }
    my $ms = $cache->{ $self->spec };

    my $get_index_range = sub {
        my ( $spec, $total ) = @_;

        my $last_index  = $total - 1;
        my $index_start = $spec->index_start;
        my $index_end   = $spec->index_end;

        if ( '#' eq $index_start ) {
            if ( '#' eq $index_end or 0 eq $index_end ) { return [$last_index] }
            $index_start = $last_index;
            $index_end   = $last_index - $index_end;
            if ( 0 > $index_end ) { $index_end = 0 }
        }
        else {
            if ( $last_index < $index_start ) {
                return [$index_start];
            }    # this will result to no hits
        }

        if ( '#' eq $index_end or $index_end > $last_index ) {
            $index_end = $last_index;
        }

        my $range =
            ( $index_start <= $index_end )
          ? [ $index_start .. $index_end ]
          : [ $index_end .. $index_start ];
        return $range;
    };

    my $set_data = sub {
        my ($val) = @_;
        my $nested = data_at( $path, $data, create => 1, key => $key );
        set_data( $nested, $key, $val );
        return $data;
    };

    # filter by tag
    my @fields     = ();
    my $field_spec = $ms->field;
    my $tag        = $field_spec->tag;
    $tag           = qr/$tag/;
    unless ( @fields =
        grep { $_->[0] =~ /$tag/ } @{ $data->{$record_key} } )
    {
        return $data;
    }

    if (defined $field_spec->indicator1) {
        my $indicator1 = $field_spec->indicator1;
        $indicator1    = qr/$indicator1/;
        unless( @fields =
            grep { defined $_->[1] && $_->[1] =~ /$indicator1/ } @fields)
        {
            return $data;
        }
    }
    if (defined $field_spec->indicator2) {
        my $indicator2 = $field_spec->indicator2;
        $indicator2    = qr/$indicator2/;
        unless( @fields =
            grep { defined $_->[2] && $_->[2] =~ /$indicator2/ } @fields)
        {
            return $data;
        }
    }

    # filter by index
    if ( $NO_LENGTH != $field_spec->index_length ) {    # index is requested
        my $index_range = $get_index_range->( $field_spec, scalar @fields );
        my $prevTag     = $EMPTY;
        my $index       = 0;
        my $tag;
        my @filtered = ();
        for my $pos ( 0 .. $#fields ) {
            $tag = $fields[$pos][0];
            $index = ( $prevTag eq $tag or $EMPTY eq $prevTag ) ? $index : 0;
            if ( array_includes( $index_range, $index ) ) {
                push @filtered, $fields[$pos];
            }
            $index++;
            $prevTag = $tag;
        }
        unless (@filtered) { return $data }
        @fields = @filtered;
    }

    # return $self->value ASAP
    if ( $self->value && !defined $ms->subfields ) {
        return $set_data->( $self->value );
    }

    if ( defined $ms->subfields ) {    # now we dealing with subfields
        # set the order of subfields
        my @sf_spec = map { $_ } @{ $ms->subfields };
        unless ( $self->pluck ) {
            @sf_spec = sort { $a->code cmp $b->code } @sf_spec;
        }

        # set invert level default
        my $invert_level = $INVERT_LEVEL_DEFAULT;
        my $codes;
        if ( $self->invert ) {
            $codes = '[^';
            $codes .= join '', map { $_->code } @sf_spec;
            $codes .= ']';
        }

        my ( @subfields, @subfield );
        my $invert_chars = sub {
            my ( $str, $start, $length ) = @_;
            for ( substr $str, $start, $length ) {
                $_ = '';
            }
            return $str;
        };

        for my $field (@fields) {
            my $start = $FIELD_OFFSET;
            for my $sf (@sf_spec) {
                # set invert level
                if ( $self->invert ) {
                    if ( $NO_LENGTH == $sf->index_length
                        && !defined $sf->char_start )
                    {    # todo add subspec check
                        next
                          if ( $invert_level == $INVERT_LEVEL_3 )
                          ;    # skip subfield spec it's already covered
                        $invert_level = $INVERT_LEVEL_3;
                    }
                    elsif ( !defined $sf->char_start )
                    {          # todo add subspec check
                        $invert_level = $INVERT_LEVEL_2;
                    }
                    else {     # todo add subspec check
                        $invert_level = $INVERT_LEVEL_1;
                    }
                }

                @subfield = ();
                my $code  =
                  ( $invert_level == $INVERT_LEVEL_3 ) ? $codes : $sf->code;
                $code     = qr/$code/;
                for ( my $i = $start ; $i < @$field ; $i += 2 ) {
                    if ( $field->[$i] =~ /$code/ ) {
                        push( @subfield, $field->[ $i + 1 ] );
                    }
                }

                if ( $invert_level == $INVERT_LEVEL_3 ) {
                    if (@subfield) { push @subfields, @subfield }

                    # return $self->value ASAP
                    if ( @subfields && $self->value ) {
                        return $set_data->( $self->value );
                    }
                    next;
                }
                next unless (@subfield);

                # filter by index
                if ( $NO_LENGTH != $sf->index_length ) {
                    my $sf_range = $get_index_range->( $sf, scalar @subfield );
                    if ( $invert_level == $INVERT_LEVEL_2 ) {    # inverted
                        @subfield = map {
                            array_includes( $sf_range, $_ )
                              ? ()
                              : $subfield[$_]
                        } 0 .. $#subfield;
                    }
                    else {    # without invert
                        @subfield =
                          map { defined $subfield[$_] ? $subfield[$_] : () }
                          @$sf_range;
                    }
                    next unless (@subfield);
                }

                # return $self->value ASAP
                if ( $self->value ) { return $set_data->( $self->value ) }

                # get substring
                my $char_start = $sf->char_start;
                if ( defined $char_start ) {
                    my $char_start =
                      ( '#' eq $char_start )
                      ? $sf->char_length * -1
                      : $char_start;
                    if ( $invert_level == $INVERT_LEVEL_1 ) {    # inverted
                        @subfield = map {
                            $invert_chars->( $_, $char_start, $sf->char_length )
                        } @subfield;
                    }
                    else {
                        @subfield =
                          map { substr $_, $char_start, $sf->char_length }
                          @subfield;
                    }
                }
                push @subfields, @subfield if (@subfield);
            }
        }

        unless (@subfields) { return $data }

        $self->split
          ? $set_data->( [@subfields] )
          : $set_data->( join( $join_char, @subfields ) );
    }
    else {    # no subfields requested
        my $char_start = $field_spec->char_start;
        if ( defined $char_start ) {
            $char_start =
              ( '#' eq $char_start )
              ? $field_spec->char_length * -1
              : $char_start;
        }
        my @mapped = ();
        for my $field (@fields) {
            my $start = $FIELD_OFFSET + 1;

            my @subfields = ();
            for ( my $i = $start ; $i < @$field ; $i += 2 ) {
                    push( @subfields, $field->[$i] );
            }
            next unless (@subfields);

            # get substring
            if ( defined $char_start ) {
                @subfields =
                  map { substr $_, $char_start, $field_spec->char_length }
                    @subfields;
            }
            push @mapped, @subfields;
        }
        unless (@mapped) { return $data }

        $self->split
          ? $set_data->( [@mapped] )
          : $set_data->( join $join_char, @mapped );
    }
    return $data;
}

1;
__END__

=encoding utf-8

=head1 NAME

Catmandu::Fix::marc_spec - reference MARC values via
L<MARCspec - A common MARC record path language|http://marcspec.github.io/MARCspec/>

=head1 SYNOPSIS

In a fix file e.g. 'my.fix':

    # Assign value of MARC leader to my.ldr.all
    marc_spec('LDR', my.ldr.all)

    # Assign values of all subfields of field 245 as a joined string
    marc_spec('245', my.title.all)

    # If field 245 exists, set string 'the title' as the value of my.title.default
    marc_spec('245', my.title.default, value:'the title')

    # Assign values of all subfields of every field 650 to my.subjects.all
    # as a joined string
    marc_spec('650', my.subjects.all)

    # Same as above with joining characters '###'
    marc_spec('650', my.subjects.all, join:'###')

    # Same as above but added as an element to the array my.append.subjects
    marc_spec('650', my.append.subjects.$append, join:'###')

    # Every value of a subfield will be an array element
    marc_spec('650', my.split.subjects, split:1)

    # Assign values of all subfields of all fields having indicator 1 = 1
    # and indicator 2 = 0 to the my.fields.indicators10 array.
    marc_spec('..._10', my.fields.indicators10.$append)

    # Assign first four characters of leader to my.firstcharpos.ldr
    marc_spec('LDR/0-3', my.firstcharpos.ldr)

    # Assign last four characters of leader to my.lastcharpos.ldr
    marc_spec('LDR/#-3', my.lastcharpos.ldr)

    # Assign value of subfield a of field 245 to my.title.proper
    marc_spec('245$a', my.title.proper)

    # Assign first two characters of subfield a of field 245 to my.title.proper
    marc_spec('245$a/0-1', my.title.charpos)

    # Assign all subfields of second field 650 to my.second.subject
    marc_spec('650[1]', my.second.subject)

    # Assign values of all subfields of last field 650 to my.last.subject
    marc_spec('650[#]', my.last.subject)

    # Assign an array of values of all subfields of the first two fields 650
    # to my.two.split.subjects
    marc_spec('650[0-1]', my.two.split.subjects, split:1)

    # Assign a joined string of values of all subfields of the last two fields 650
    # to my.two.join.subjects
    marc_spec('650[#-1]', my.two.join.subjects, join:'###')


    # Assign value of first subfield a of all fields 020 to my.isbn.number
    marc_spec('020$a[0]', my.isbn.number)

    # Assign value of first subfield q of first field 020 to my.isbn.qual.one
    marc_spec('020[0]$q[0]', my.isbn.qual.none)

    # Assign values of subfield q and a in the order stated as an array
    # to  my.isbns.pluck.all
    # without option 'pluck:1' the elments will be in 'natural' order
    # see example below
    marc_spec('020$q$a', my.isbns.pluck.all, split:1, pluck:1)

    # Assign value of last subfield q and second subfield a
    # in 'natural' order of last field 020 as an array to my.isbn.qual.other
    marc_spec('020[#]$q[#]$a[1]', my.isbn.qual.other, split:1)

    # Assign first five characters of value of last subfield q and last character
    # of value of second subfield a in 'natural' order of all fields 020
    # as an array to  my.isbn.qual.substring.other
    marc_spec('020$q[#]/0-4$a[1]/#', my.isbn.qual.substring.other, split:1)

    # Assign values of of all other subfields than a of field 020
    # to my.isbn.other.subfields
    marc_spec('020$a' my.isbn.other.subfields, invert:1)

And then on command line:

    catmandu convert MARC to YAML --fix my.fix < perl_books.mrc

See L<Catmandu Importers|http://librecat.org/Catmandu/#importers> and
L<Catmandu Fixes|http://librecat.org/Catmandu/#fixes> for a deeper
understanding of how L<Catmandu|http://librecat.org/> works.

=head1 DESCRIPTION

L<Catmandu::Fix::marc_spec|Catmandu::Fix::marc_spec> is a fix for the
famous L<Catmandu Framework|Catmandu>.

For the most part it behaves like
L<Catmandu::Fix::marc_map|Catmandu::Fix::marc_map> , but has a more fine
grained method to reference MARC data content.

See L<MARCspec - A common MARC record path language|http://marcspec.github.io/MARCspec/>
for documentation on the path syntax.

=head1 METHODS

=head2 marc_spec(Str, Str, Str, ...)

First parameter must be a string, following the syntax of
L<MARCspec - A common MARC record path language|http://marcspec.github.io/MARCspec/>.
Do always use single quotes with this first parameter.

Second parameter is a string describing the variable or the variable path
to assign referenced values to
(see L<Catmandu Paths|http://librecat.org/Catmandu/#paths>).

You may use one of $first, $last, $prepend or $append to add
referenced data values to a specific position of an array
(see L<Catmandu Wildcards|http://librecat.org/Catmandu/#wildcards>).

    # INPUT
    [245,1,0,"a","Cross-platform Perl /","c","Eric F. Johnson."]

    # CALL
    marc_spec('245', my.title.$append)

    # OUTPUT
    {
      my {
        title [
            [0] "Cross-platform Perl /Eric F. Johnson."
        ]
      }

    }

Third and every other parameters are optional and must
be in the form of key:value (see L</"OPTONS"> for a deeper
understanding of options).

=head1 OPTIONS

=head2 split

If split is set to 1, every fixed fields value or every subfield will be
an array element.

    # INPUT
    [650," ",0,"a","Perl (Computer program language)"],
    [650," ",0,"a","Web servers."]

    # CALL
    marc_spec('650', my.subjects, split:1)

    # OUTPUT
    {
      my {
        subjects [
            [0] "Perl (Computer program language)",
            [1] "Web servers."
        ]
      }
    }


=head2 join

If set, value of join will be used to join the referenced data content.
This will only have an effect if option split is undefined (not set or set to 0).

    # INPUT
    [650," ",0,"a","Perl (Computer program language)"],
    [650," ",0,"a","Web servers."]

    # CALL
    marc_spec('650', my.subjects, join:'###')

    # OUTPUT
    {
      my {
        subjects "Perl (Computer program language)###Web servers."
      }
    }

=head2 pluck

This has only an effect on subfield values. By default subfield reference
happens in 'natural' order (first number 0 to 9 and then letters a to z).

    # INPUT
    ["020"," ", " ","a","0491001304","q","black leather"]

    # CALL
    marc_spec('020$q$a', my.isbn, split:1)

    # OUTPUT
    {
      my {
        isbn [
            [0] 0491001304,
            [1] "black leather"
        ]
      }
    }


If pluck is set to 1, values will be referenced by the order stated in the
MARCspec.

    # INPUT
    ["020"," ", " ","a","0491001304","q","black leather"]

    # CALL
    marc_spec('020$q$a', my.plucked.isbn, split:1, pluck:1)

    # OUTPUT
    {
      my {
        isbn [
            [0] "black leather",
            [1] 0491001304
        ]
      }
    }

=head2 value

If set to a value, this value will be assigned to $var if MARCspec references
data content (if the field or subfield exists).

In case two or more subfields are referenced, the value will be assigned to $var if
at least one of them exists:

    # INPUT
    ["020"," ", " ","a","0491001304"]

    # CALL
    marc_spec('020$a$q', my.isbn, value:'one subfield exists')

    # OUTPUT
    {
      my {
        isbn "one subfield exists"
      }
    }

=head2 record

The value of option record is used as a record key. Thus not the default record,
but the other record will be processed.

This option is useful if you created another (temporary) record and want to
work on this record instead of the default record.

    copy_field(record, record2)
    # do some stuff with record2 an later
    marc_spec('245$a', my.title.other, record:'record2')

=head2 invert

This has only an effect on subfields (values). If set to 1 it will invert the
last pattern for every subfield. E.g.

   # references all subfields but not subfield a and q
   marc_spec('020$a$q' my.other.subfields, invert:1)

   # references all subfields but not subfield a and not the last repetition
   # of subfield q
   marc_spec('020$a$q[#]' my.other.subfields, invert:1)

   # references all but not the last two characters of first subfield a
   marc_spec('020$a[0]/#-1' my.other.subfields, invert:1)

=head1 BUGS AND LIMITATIONS

This version of is agnostic of Subspecs as described in  L<MARCspec - A common MARC record path language|http://marcspec.github.io/MARCspec/>.
Later versions will include this feature.

Please report any bugs to L<https://github.com/cKlee/Catmandu-Fix-marc_spec/issues>.

=head1 AUTHOR

Carsten Klee E<lt>klee@cpan.orgE<gt>

=head1 CONTRIBUTORS

=over

=item * Johann Rolschewski, C<< <jorol at cpan> >>,

=item * Patrick Hochstenbach, C<< <patrick.hochstenbach at ugent.be> >>,

=item * Nicolas Steenlant, C<< <nicolas.steenlant at ugent.be> >>

=back

=head1 LICENSE AND COPYRIGHT

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=over

=item * L<MARCspec - A common MARC record path language|http://marcspec.github.io/MARCspec/>

=item * L<Catmandu|http://librecat.org/>

=item * L<Catmandu Importers|http://librecat.org/Catmandu/#importers>

=item * L<Catmandu Importers|http://librecat.org/Catmandu/#importers>

=item * L<Catmandu Fixes|http://librecat.org/Catmandu/#fixes>

=item * L<Catmandu::MARC::Fix::marc_map|Catmandu::MARC::Fix::marc_map>

=item * L<Catmandu Paths|http://librecat.org/Catmandu/#paths>

=item * L<Catmandu Wildcards|http://librecat.org/Catmandu/#wildcards>

=item * L<MARC::Spec|MARC::Spec>

=item * L<Catmandu::Fix|Catmandu::Fix>

=item * L<Catmandu::MARC|Catmandu::MARC>

=back

=cut
