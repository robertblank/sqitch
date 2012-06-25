package App::Sqitch::Plan;

use v5.10.1;
use utf8;
use App::Sqitch::Plan::Tag;
use App::Sqitch::Plan::Step;
use App::Sqitch::Plan::Blank;
use App::Sqitch::Plan::Pragma;
use Path::Class;
use App::Sqitch::Plan::StepList;
use App::Sqitch::Plan::LineList;
use namespace::autoclean;
use Moose;
use constant SYNTAX_VERSION => '1.0.0-a1';

our $VERSION = '0.32';

has sqitch => (
    is       => 'ro',
    isa      => 'App::Sqitch',
    required => 1,
    weak_ref => 1,
);

has _plan => (
    is         => 'ro',
    isa        => 'HashRef',
    builder    => 'load',
    init_arg   => 'plan',
    lazy       => 1,
    required   => 1,
);

has position => (
    is       => 'rw',
    isa      => 'Int',
    required => 1,
    default  => -1,
);

sub load {
    my $self = shift;
    my $file = $self->sqitch->plan_file;
    # XXX Issue a warning if file does not exist?
    return {
        steps => App::Sqitch::Plan::StepList->new,
        lines => App::Sqitch::Plan::LineList->new(
            $self->_version_line,
        ),
    } unless -f $file;
    my $fh = $file->open('<:encoding(UTF-8)')
        or $self->sqitch->fail( "Cannot open $file: $!" );
    return $self->_parse($file, $fh);
}

sub _parse {
    my ( $self, $file, $fh ) = @_;

    my @lines;         # List of lines.
    my @steps;         # List of steps.
    my @curr_steps;    # List of steps since last tag.
    my %line_no_for;   # Maps tags and steps to line numbers.
    my %step_named;    # Maps step names to step objects.
    my %tag_steps;     # Maps steps in current tag section to line numbers.
    my $seen_version;  # Have we seen a version pragma?
    my $prev_tag;      # Last seen tag.
    my $prev_step;     # Last seen step.

    LINE: while ( my $line = $fh->getline ) {
        chomp $line;

        # Grab blank lines first.
        if ($line =~ /\A(?<lspace>[[:blank:]]*)(?:#(?<comment>.+)|$)/) {
            my $line = App::Sqitch::Plan::Blank->new( plan => $self, %+ );
            push @lines => $line;
            next LINE;
        }

        # Grab inline comment.
        $line =~ s/(?<rspace>[[:blank:]]*)(?:[#](?<comment>.*))?$//;
        my %params = %+;

        # Grab pragmas.
        if ($line =~ /
           \A                             # Beginning of line
           (?<lspace>[[:blank:]]*)?       # Optional leading space
           [%]                            # Required %
           (?<hspace>[[:blank:]]*)?       # Optional space
           (?<name>                       # followed by name consisting of...
               [^[:punct:]]               #     not punct
               (?:                        #     followed by...
                   [^[:blank:]=]*?        #         any number non-blank, non-=
                   [^[:punct:][:blank:]]  #         one not blank or punct
               )?                         #     ... optionally
           )                              # ... required
           (?:                            # followed by value consisting of...
               (?<lopspace>[[:blank:]]*)  #     Optional blanks
               (?<operator>=)             #     Required =
               (?<ropspace>[[:blank:]]*)  #     Optional blanks
               (?<value>.+)               #     String value
           )?                             # ... optionally
           $                              # end of line
        /x) {
            if ($+{name} eq 'syntax-version') {
                # Set explicit version in case we write it out later. In
                # future releases, may change parsers depending on the
                # version.
                $params{value} = SYNTAX_VERSION;
                $seen_version = 1;
            }
            my $prag = App::Sqitch::Plan::Pragma->new( plan => $self, %+, %params );
            push @lines => $prag;
            next LINE;
        }

        # Is it a tag or a step?
        my $type = $line =~ /^[[:blank:]]*[@]/ ? 'tag' : 'step';
        my $name_re = qr/
             [^[:punct:]]               #     not punct
             (?:                        #     followed by...
                 [^[:blank:]@]*         #         any number non-blank, non-@
                 [^[:punct:][:blank:]]  #         one not blank or punct
             )?                         #     ... optionally
        /x;

        # Not sure why these must be global, but lexical always end up empty.
        our (@req, @con) = ();
        use re 'eval';
        $line =~ /
           ^                                    # Beginning of line
           (?<lspace>[[:blank:]]*)?             # Optional leading space
           (?:                                  # followed by...
               [@]                              #     @ for tag
           |                                    # ...or...
               (?<lopspace>[[:blank:]]*)        #     Optional blanks
               (?<operator>[+-])                #     Required + or -
               (?<ropspace>[[:blank:]]*)        #     Optional blanks
           )?                                   # ... optionally
           (?<name>$name_re)                    # followed by name
           (?:                                  # followed by...
               (?<pspace>[[:blank:]]+)          #     Blanks
               (?:                              #     followed by...
                   :([@]?$name_re)              #         A requires spec
                   (?{ push @req, $^N })        #         which we capture
                   [[:blank:]]*                 #         optional blanks
               |                                #     ...or...
                   !([@]?$name_re)              #         A conflicts spec
                   (?{ push @con, $^N })        #         which we capture
                   [[:blank:]]*                 #         optional blanks
               )+                               #     ... one or more times
           )?                                   # ... optionally
           $                                    # end of line
        /x;

        %params = (
            %params, %+,
            ( $type eq 'tag' ? () : ( conflicts => [@con], requires => [@req] ) ),
        );

        # Make sure we have a valid name.
        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number,
            qq{: Invalid $type "$line"; ${type}s must not begin with },
            'punctuation or end in punctuation or digits following punctuation'
        ) if !$params{name} || $params{name} =~ /[[:punct:]][[:digit:]]*\z/;

        # It must not be a reserved name.
        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number,
            qq{: "$params{name}" is a reserved name},
        ) if $params{name} eq 'HEAD' || $params{name} eq 'ROOT';

        # It must not loo, like a SHA1 hash.
        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number,
            qq{: "$params{name}" is invalid because it could be confused with a SHA1 ID},
        ) if $params{name} =~ /^[0-9a-f]{40}/;

        if ($type eq 'tag') {
            # Fail if no steps.
            unless ($prev_step) {
                $self->sqitch->fail(
                    "Error in $file at line ",
                    $fh->input_line_number,
                    qq{: \u$type "$params{name}" declared without a preceding step},
                );
            }

            # Fail on duplicate tag.
            my $key = '@' . $params{name};
            if ( my $at = $line_no_for{$key} ) {
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number,
                    qq{: \u$type "$params{name}" duplicates earlier declaration on line $at},
                );
            }

            # Fail on dependencies.
            if (@req || @con) {
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number,
                    ': Tags may not specify dependencies'
                );
            }

            if (@curr_steps) {
                # Sort all steps up to this tag by their dependencies.
                push @steps => $self->sort_steps(\%line_no_for, @curr_steps);
                @curr_steps = ();
            }

            # Create the tag and associate it with the previous step.
            $prev_tag = App::Sqitch::Plan::Tag->new(
                plan => $self,
                step => $prev_step,
                %params,
            );

            # Keep track of everything and clean up.
            $prev_step->add_tag($prev_tag);
            push @lines => $prev_tag;
            %line_no_for = (%line_no_for, %tag_steps, $key => $fh->input_line_number);
            %tag_steps = ();
        } else {
            # Fail on duplicate step since last tag.
            if ( my $at = $tag_steps{ $params{name} } ) {
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number,
                    qq{: \u$type "$params{name}" duplicates earlier declaration on line $at},
                );
            }

            $tag_steps{ $params{name} } = $fh->input_line_number;
            push @curr_steps => $prev_step = App::Sqitch::Plan::Step->new(
                plan => $self,
                ( $prev_tag ? ( since_tag => $prev_tag ) : () ),
                %params,
            );
            push @lines => $prev_step;

            if (my $duped = $step_named{ $params{name} }) {
                # Mark previously-seen step of same name as duped.
                $duped->suffix($prev_tag->format_name);
            }
            $step_named{ $params{name} } = $prev_step;
        }
    }

    # Sort and store any remaining steps.
    push @steps => $self->sort_steps(\%line_no_for, @curr_steps) if @curr_steps;

    # We should have a version pragma.
    unshift @lines => $self->_version_line unless $seen_version;

    return {
        steps => App::Sqitch::Plan::StepList->new(@steps),
        lines => App::Sqitch::Plan::LineList->new(@lines),
    };
}

sub _version_line {
    App::Sqitch::Plan::Pragma->new(
        plan     => shift,
        name     => 'syntax-version',
        operator => '=',
        value    => SYNTAX_VERSION,
    );
}

sub sort_steps {
    my $self = shift;
    my $seen = ref $_[0] eq 'HASH' ? shift : {};

    my %obj;             # maps step names to objects.
    my %pairs;           # all pairs ($l, $r)
    my %npred;           # number of predecessors
    my %succ;            # list of successors
    for my $step (@_) {

        # Stolen from http://cpansearch.perl.org/src/CWEST/ppt-0.14/bin/tsort.
        my $name = $step->name;
        $obj{$name} = $step;
        my $p = $pairs{$name} = {};
        $npred{$name} += 0;

        # XXX Ignoring conflicts for now.
        for my $dep ( $step->requires ) {

            # Skip it if it's a step from an earlier tag.
            next if exists $seen->{$dep};
            $p->{$dep}++;
            $npred{$dep}++;
            push @{ $succ{$name} } => $dep;
        }
    }

    # Stolen from http://cpansearch.perl.org/src/CWEST/ppt-0.14/bin/tsort.
    # Create a list of steps without predecessors
    my @list = grep { !$npred{$_->name} } @_;

    my @ret;
    while (@list) {
        my $step = pop @list;
        unshift @ret => $step;
        foreach my $child ( @{ $succ{$step->name} } ) {
            unless ( $pairs{$child} ) {
                my $sqitch = $self->sqitch;
                my $type = $child =~ /^[@]/ ? 'tag' : 'step';
                $self->sqitch->fail(
                    qq{Unknown $type "$child" required in },
                    $step->deploy_file,
                );
            }
            push @list, $obj{$child} unless --$npred{$child};
        }
    }

    if ( my @cycles = map { $_->name } grep { $npred{$_->name} } @_ ) {
        my $last = pop @cycles;
        $self->sqitch->fail(
            'Dependency cycle detected beween steps "',
            join( ", ", @cycles ),
            qq{ and "$last"}
        );
    }
    return @ret;
}

sub open_script {
    my ( $self, $file ) = @_;
    return $file->open('<:encoding(UTF-8)') or $self->sqitch->fail(
        "Cannot open $file: $!"
    );
}

sub lines          { shift->_plan->{lines}->items }
sub steps          { shift->_plan->{steps}->steps }
sub count          { shift->_plan->{steps}->count }
sub index_of       { shift->_plan->{steps}->index_of(shift) }
sub get            { shift->_plan->{steps}->get(shift) }
sub first_index_of { shift->_plan->{steps}->first_index_of(@_) }
sub step_at        { shift->_plan->{steps}->step_at(shift) }

sub seek {
    my ( $self, $key ) = @_;
    my $index = $self->index_of($key);
    $self->sqitch->fail(qq{Cannot find step "$key" in plan})
        unless defined $index;
    $self->position($index);
    return $self;
}

sub reset {
    my $self = shift;
    $self->position(-1);
    return $self;
}

sub next {
    my $self = shift;
    if ( my $next = $self->peek ) {
        $self->position( $self->position + 1 );
        return $next;
    }
    $self->position( $self->position + 1 ) if defined $self->current;
    return undef;
}

sub current {
    my $self = shift;
    my $pos = $self->position;
    return if $pos < 0;
    $self->_plan->{steps}->step_at( $pos );
}

sub peek {
    my $self = shift;
    $self->_plan->{steps}->step_at( $self->position + 1 );
}

sub last {
    shift->_plan->{steps}->step_at( -1 );
}

sub do {
    my ( $self, $code ) = @_;
    while ( local $_ = $self->next ) {
        return unless $code->($_);
    }
}

sub add_tag {
    my ( $self, $name ) = @_;
    $name =~ s/^@//;
    $self->_is_valid(tag => $name);

    my $plan  = $self->_plan;
    my $steps = $plan->{steps};
    my $key   = "\@$name";

    $self->sqitch->fail(qq{Tag "$key" already exists})
        if defined $steps->index_of($key);

    my $step = $steps->last_step or $self->sqitch->fail(
        qq{Cannot apply tag "$key" to a plan with no steps}
    );

    my $tag = App::Sqitch::Plan::Tag->new(
        plan => $self,
        name => $name,
        step => $step,
    );

    $step->add_tag($tag);
    $steps->index_tag( $steps->index_of( $step->id ), $tag );
    $plan->{lines}->append( $tag );
    return $tag;
}

sub add_step {
    my ( $self, $name, $requires, $conflicts ) = @_;
    $self->_is_valid(step => $name);

    my $plan  = $self->_plan;
    my $steps = $plan->{steps};

    if (defined( my $idx = $steps->index_of($name . '@HEAD') )) {
        my $tag_idx = $steps->index_of_last_tagged;
        $self->sqitch->fail(
            qq{Step "$name" already exists.\n},
            'Use "sqitch rework" to copy and rework it'
        );
    }

    my $step = App::Sqitch::Plan::Step->new(
        plan      => $self,
        name      => $name,
        requires  => $requires  ||= [],
        conflicts => $conflicts ||= [],
        (@{ $requires } || @{ $conflicts } ? ( pspace => ' ' ) : ()),
    );

    # Make sure dependencies are specified.
    $self->_check_dependencies($step, 'add');

    # We good.
    $steps->append( $step );
    $plan->{lines}->append( $step );
    return $step;
}

sub rework_step {
    my ( $self, $name, $requires, $conflicts ) = @_;
    my $plan  = $self->_plan;
    my $steps = $plan->{steps};
    my $idx   = $steps->index_of($name . '@HEAD') // $self->sqitch->fail(
        qq{Step "$name" does not exist.\n},
        qq{Use "sqitch add $name" to add it to the plan},
    );

    my $tag_idx = $steps->index_of_last_tagged;
    $self->sqitch->fail(
        qq{Cannot rework "$name" without an intervening tag.\n},
        'Use "sqitch tag" to create a tag and try again'
    ) if !defined $tag_idx || $tag_idx < $idx;

    my ($tag) = $steps->step_at($tag_idx)->tags;
    unshift @{ $requires ||= [] } => $name . $tag->format_name;

    my $orig = $steps->step_at($idx);
    my $new  = App::Sqitch::Plan::Step->new(
        plan      => $self,
        name      => $name,
        requires  => $requires,
        conflicts => $conflicts ||= [],
        (@{ $requires } || @{ $conflicts } ? ( pspace => ' ' ) : ()),
    );

    # Make sure dependencies are specified.
    $self->_check_dependencies($new, 'rework');

    # We good.
    $orig->suffix($tag->format_name);
    $steps->append( $new );
    $plan->{lines}->append( $new );
    return $new;
}

sub _check_dependencies {
    my ( $self, $step, $action ) = @_;
    my $steps = $self->_plan->{steps};
    for my $req ( $step->requires ) {
        next if defined $steps->index_of($req =~ /@/ ? $req : $req . '@HEAD');
        my $name = $step->name;
        $self->sqitch->fail(
            qq{Cannot $action step "$name": },
            qq{requires unknown change "$req"}
        );
    }
    return $self;
}

sub _is_valid {
    my ( $self, $type, $name ) = @_;
    $self->sqitch->fail(qq{"$name" is a reserved name})
        if $name eq 'HEAD' || $name eq 'ROOT';
    $self->sqitch->fail(
        qq{"$name" is invalid because it could be confused with a SHA1 ID}
    ) if $name =~ /^[0-9a-f]{40}/;

    $self->sqitch->fail(
        qq{"$name" is invalid: ${type}s must not begin with punctuation },
        'or end in punctuation or digits following punctuation'
    ) unless $name =~ /
        ^                          # Beginning of line
        [^[:punct:]]               # not punct
        (?:                        # followed by...
            [^[:blank:]@#]*?       #     any number non-blank, non-@, non-#.
            [^[:punct:][:blank:]]  #     one not blank or punct
        )?                         # ... optionally
        $                          # end of line
    /x && $name !~ /[[:punct:]][[:digit:]]*\z/;
}

sub write_to {
    my ( $self, $file ) = @_;

    my $fh = IO::File->new(
        $file,
        '>:encoding(UTF-8)'
    ) or $self->sqitch->fail( "Cannot open $file: $!" );
    $fh->say($_->as_string) for $self->lines;
    $fh->close or die "Error closing $file: $!\n";
    return $self;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan - Sqitch Deployment Plan

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  while (my $step = $plan->next) {
      say "Deploy ", $step->format_name;
  }

=head1 Description

App::Sqitch::Plan provides the interface for a Sqitch plan. It parses a plan
file and provides an iteration interface for working with the plan.

=head1 Interface

=head2 Constants

=head3 C<SYNTAX_VERSION>

Returns the current version of the Sqitch plan syntax. Used for the
C<%sytax-version> pragma.

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );

Instantiates and returns a App::Sqitch::Plan object. Takes a single parameter:
an L<App::Sqitch> object.

=head2 Accessors

=head3 C<sqitch>

  my $sqitch = $cmd->sqitch;

Returns the L<App::Sqitch> object that instantiated the plan.

=head3 C<position>

Returns the current position of the iterator. This is an integer that's used
as an index into plan. If C<next()> has not been called, or if C<reset()> has
been called, the value will be -1, meaning it is outside of the plan. When
C<next> returns C<undef>, the value will be the last index in the plan plus 1.

=head2 Instance Methods

=head3 C<index_of>

  my $index      = $plan->index_of('6c2f28d125aff1deea615f8de774599acf39a7a1');
  my $foo_index  = $plan->index_of('@foo');
  my $bar_index  = $plan->index_of('bar');
  my $bar1_index = $plan->index_of('bar@alpha')
  my $bar2_index = $plan->index_of('bar@HEAD');

Returns the index of the specified step. Returns C<undef> if no such step
exists. The argument may be any one of:

=over

=item * An ID

  my $index = $plan->index_of('6c2f28d125aff1deea615f8de774599acf39a7a1');

This is the SHA1 hash of a step or tag. Currently, the full 40-character hexed
hash string must be specified.

=item * A step name

  my $index = $plan->index_of('users_table');

The name of a step. Will throw an exception if the named step appears more
than once in the list.

=item * A tag name

  my $index = $plan->index_of('@beta1');

The name of a tag, including the leading C<@>.

=item * A tag-qualified step name

  my $index = $plan->index_of('users_table@beta1');

The named step as it was last seen in the list before the specified tag.

=back

=head3 C<get>

  my $step = $plan->get('6c2f28d125aff1deea615f8de774599acf39a7a1');
  my $foo  = $plan->index_of('@foo');
  my $bar  = $plan->index_of('bar');
  my $bar1 = $plan->index_of('bar@alpha')
  my $bar2 = $plan->index_of('bar@HEAD');

Returns the step corresponding to the specified ID or name. The argument may
be in any of the formats described for C<index_of()>.

=head3 C<first_index_of>

  my $index = $plan->first_index_of($step_name);
  my $index = $plan->first_index_of($step_name, $step_or_tag_name);

Returns the index of the first instance of the named step in the plan. If a
second argument is passed, the index of the first instance of the step
I<after> the the index of the second argument will be returned. This is useful
for getting the index of a step as it was deployed after a particular tag, for
example, to get the first index of the F<foo> step since the C<@beta> tag, do
this:

  my $index = $plan->first_index_of('foo', '@beta');

You can also specify the first instance of a step after another step,
including such a step at the point of a tag:

  my $index = $plan->first_index_of('foo', 'users_table@beta1');

The second argument must unambiguously refer to a single step in the plan. As
such, it should usually be a tag name or tag-qualified step name. Returns
C<undef> if the step does not appear in the plan, or if it does not appear
after the specified second argument step name.

=head3 C<step_at>

  my $step = $plan->step_at($index);

Returns the step at the specified index.

=head3 C<seek>

  $plan->seek('@foo');
  $plan->seek('bar');

Move the plan position to the specified step. Dies if the step cannot be found
in the plan.

=head3 C<reset>

   $plan->reset;

Resets iteration. Same as C<< $plan->position(-1) >>, but better.

=head3 C<next>

  while (my $step = $plan->next) {
      say "Deploy ", $step->format_name;
  }

Returns the next L<step|App::Sqitch::Plan::Step> in the plan. Returns C<undef>
if there are no more steps.

=head3 C<last>

  my $step = $plan->last;

Returns the last step in the plan. Does not change the current position.

=head3 C<current>

   my $step = $plan->current;

Returns the same step as was last returned by C<next()>. Returns C<undef> if
C<next()> has not been called or if the plan has been reset.

=head3 C<peek>

   my $step = $plan->peek;

Returns the next step in the plan without incrementing the iterator. Returns
C<undef> if there are no more steps beyond the current step.

=head3 C<steps>

  my @steps = $plan->steps;

Returns all of the steps in the plan. This constitutes the entire plan.

=head3 C<count>

  my $count = $plan->count;

Returns the number of steps in the plan.

=head3 C<lines>

  my @lines = $plan->lines;

Returns all of the lines in the plan. This includes all the
L<steps|App::Sqitch::Plan::Step>, L<tags|App::Sqitch::Plan::Tag>,
L<pragmas|App::Sqitch::Plan::Pragma>, and L<blank
lines|App::Sqitch::Plan::Blank>.

=head3 C<do>

  $plan->do(sub { say $_[0]->name; return $_[0]; });
  $plan->do(sub { say $_->name;    return $_;    });

Pass a code reference to this method to execute it for each step in the plan.
Each step will be stored in C<$_> before executing the code reference, and
will also be passed as the sole argument. If C<next()> has been called prior
to the call to C<do()>, then only the remaining steps in the iterator will
passed to the code reference. Iteration terminates when the code reference
returns false, so be sure to have it return a true value if you want it to
iterate over every step.

=head3 C<write_to>

  $plan->write_to($file);

Write the plan to the named file, including. comments and white space from the
original plan file.

=head3 C<open_script>

  my $file_handle = $plan->open_script( $step->deploy_file );

Opens the script file passed to it and returns a file handle for reading. The
script file must be encoded in UTF-8.

=head3 C<load>

  my $plan_data = $plan->load;

Loads the plan data. Called internally, not meant to be called directly, as it
parses the plan file and deploy scripts every time it's called. If you want
the all of the steps, call C<steps()> instead.

=head3 C<sort_steps>

  @steps = $plan->sort_steps(@steps);
  @steps = $plan->sort_steps( { '@foo' => 1, 'bar' => 1 }, @steps );

Sorts a list of steps in dependency order and returns them. If the first
argument is a hash reference, its keys should be previously-seen step and tag
names that can be assumed to be satisfied requirements for the succeeding
steps.

=head3 C<add_tag>

  $plan->add_tag('whee');

Adds a tag to the plan. Exits with a fatal error if the tag already
exists in the plan.

=head3 C<add_step>

  $plan->add_step( 'whatevs' );
  $plan->add_step( 'widgets', [qw(foo bar)], [qw(dr_evil)] );

Adds a step to the plan. The second argument specifies a list of required
steps. The third argument specifies a list of conflicting steps. Exits with a
fatal error if the step already exists, or if the any of the dependencies are
unknown.

=head3 C<rework_step>

  $plan->rework_step( 'whatevs' );
  $plan->rework_step( 'widgets', [qw(foo bar)], [qw(dr_evil)] );

Reworks an existing step. Said step must already exist in the plan and be
tagged or have a tag following it or an exception will be thrown. The previous
occurrence of the step will have the suffix of the most recent tag added to
it, and a new tag instance will be added to the list.

=head1 See Also

=over

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
