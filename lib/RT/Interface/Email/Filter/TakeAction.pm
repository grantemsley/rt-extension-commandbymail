package RT::Interface::Email::Filter::TakeAction;

use warnings;
use strict;

our @REGULAR_ATTRIBUTES = qw(Queue Status Priority FinalPriority
                             TimeWorked TimeLeft TimeEstimated Subject );
our @DATE_ATTRIBUTES    = qw(Due Starts Started Resolved Told);
our @LINK_ATTRIBUTES    = qw(MemberOf Parents Members Children
            HasMember RefersTo ReferredToBy DependsOn DependedOnBy);

=head2 my commands

Queue: <name> Set new queue for the ticket
Status: <status> Set new status, one of new, open, stalled,
resolved, rejected or deleted
Owner: <username> Set new owner using the given username
FinalPriority: <#> Set new final priority to the given value (1-99)
Priority: <#> Set new priority to the given value (1-99)
Subject: <string> Set new subject to the given string
Due: <new timestamp> Set new due date/timestamp, or 0 to disable.
+AddCc: <address> Add new Cc watcher using the email address
+DelCc: <address> Remove email address as Cc watcher
+AddAdminCc: <address> Add new AdminCc watcher using the email address
+DelAdminCc: <address> Remove email address as AdminCc watcher
+AddRequestor: <address> Add new requestor using the email address
+DelRequestor: <address> Remove email address as requestor
Starts: <new timestamp>
Started: <new timestamp>
TimeWorked: <minutes> Replace the tickets 'timeworked' value.
TimeEstimated: <minutes>
TimeLeft: <minutes>
DependsOn:
DependedOnBy:
RefersTo:
ReferredToBy:
HasMember:
MemberOf:
CustomField-C<CFName>:
CF-C<CFName>:

=cut

sub GetCurrentUser {
    my %args = (
        Message       => undef,
        RawMessageRef => undef,
        CurrentUser   => undef,
        AuthLevel     => undef,
        Action        => undef,
        Ticket        => undef,
        Queue         => undef,
        @_
    );

    warn "We're in it";

    # If the user isn't asking for a comment or a correspond,
    # bail out
    if ( $args{'Action'} !~ /^(?:comment|correspond)$/i ) {
        warn "bad action";
        return ( $args{'CurrentUser'}, $args{'AuthLevel'} );
    }

    my @content;
    warn "after the action";
    my @parts = $args{'Message'}->parts_DFS;
    foreach my $part (@parts) {

        #if it looks like it has pseudoheaders, that's our content
        if ( $part->stringify_body =~ /^(?:\S+):/m ) {
            warn "Got it";
            @content = $part->bodyhandle->as_lines();

            last;
        }

    }
    use YAML;
    warn YAML::Dump( \@content );
    warn "walking lines";
    my @items;
    foreach my $line (@content) {
        last if ( $line !~ /^(?:(\S+)\s*?:\s*?(.*)\s*?|)$/ );
        push( @items, $1 => $2 );
    }
    my %cmds;
    while ( my $key = lc shift @items ) {
        my $val = shift @items;
        $val =~ s/^\s+|\s+$//g; # strip leading and trailing spaces
        if ( $key =~ /^(?:Add|Del)/i ) {
            push @{ $cmds{$key} }, $val;
        } else {
            $cmds{$key} = $val;
        }
    }

    my %results;

    my $ticket_as_user = RT::Ticket->new( $args{'CurrentUser'} );
    my $queue          = RT::Queue->new( $args{'CurrentUser'} );
    if ( $cmds{'queue'} ) {
        $queue->Load( $cmds{'queue'} );
    }

    if ( !$queue->id ) {
        $queue->Load( $args{'Queue'}->id );
    }

    my $custom_fields = $queue->TicketCustomFields;

    # If we're updating.
    if ( $args{'Ticket'}->id ) {
        $ticket_as_user->Load( $args{'Ticket'}->id );

        foreach my $attribute (@REGULAR_ATTRIBUTES) {
            next unless ( defined $cmds{ lc $attribute }
                and ( $ticket_as_user->$attribute() ne $cmds{ lc $attribute } ) );

            _SetAttribute(
                $ticket_as_user,        $attribute,
                $cmds{ lc $attribute }, \%results
            );
        }

        foreach my $attribute (@DATE_ATTRIBUTES) {
            next unless ( $cmds{ lc $attribute } );
            my $date = RT::Date->new( $args{'CurrentUser'} );
            $date->Set(
                Format => 'unknown',
                value  => $cmds{ lc $attribute }
            );
            _SetAttribute( $ticket_as_user, $attribute, $date->ISO,
                \%results );
            $results{ lc $attribute }->{value} = $cmds{ lc $attribute };
        }

        foreach my $base_attribute (qw(Requestor Cc AdminCc)) {
            foreach my $attribute ( $base_attribute, $base_attribute . "s" ) {
                if ( my $delete = $cmds{ lc "del" . $attribute } ) {
                    foreach my $email (@$delete) {
                        _SetWatcherAttribute( $ticket_as_user, "DelWatcher",
                            "del" . $attribute,
                            $base_attribute, $email );
                    }
                    if ( my $add = $cmds{ lc "add" . $attribute } ) {
                        foreach my $email (@$add) {
                            _SetWatcherAttribute( $ticket_as_user,
                                "AddWatcher", "add" . $attribute,
                                $base_attribute, $email );
                        }
                    }
                }
            }
        }
        foreach my $type ( @LINK_ATTRIBUTES ) {
            next unless $cmds{ lc $type };
            my ($val, $msg) = $ticket_as_user->AddLink(
                Type => $ticket_as_user->LINKTYPEMAP->{$type}->{'Type'},
                Link => $cmds{ lc $type },
            );
            $results{ $type } = {
                value => $cmds{ lc $type },
                result => $val,
                message => $msg,
            };
        }

        while ( my $cf = $custom_fields->Next ) {
            next unless ( defined $cmds{ lc $cf->Name } );
            my ( $val, $msg ) = $ticket_as_user->AddCustomFieldValue(
                Field => $cf->id,
                Value => $cmds{ lc $cf->Name }
            );
            $results{ $cf->Name } = {
                value   => $cmds{ lc $cf->Name },
                result  => $val,
                message => $msg
            };
        }
        return ( $args{'CurrentUser'}, $args{'AuthLevel'} );

    } else {

        warn "Create new ticket";

        my %create_args = ();
        foreach my $attr (@REGULAR_ATTRIBUTES) {
            next unless exists $cmds{ lc $attr };
            $create_args{$attr} = $cmds{ lc $attr };
        }
        foreach my $attr (@DATE_ATTRIBUTES) {
            next unless exists $cmds{ lc $attr };
            my $date = RT::Date->new( $args{'CurrentUser'} );
            $date->Set(
                Format => 'unknown',
                Value  => $cmds{ lc $attr }
            );
            $create_args{$attr} = $date->ISO;
        }

        # Canonicalize links
        foreach my $attr (@LINK_ATTRIBUTES) {
            $create_args{$attr} = $cmds{lc $attr};

        }

        # Canonicalize custom fields
        while ( my $cf = $custom_fields->Next ) {
            next unless ( exists $cmds{ lc $cf->Name } );
            $create_args{ 'CustomField-' . $cf->id } = $cmds{ lc $cf->Name };

        }

        # Canonicalize watchers
        # First of all fetch default values
        $create_args{'Requestor'} = [ $args{'CurrentUser'}->id ];
        $create_args{'Cc'} = [
            ParseCcAddressesFromHead(
                Head        => $args{'Message'}->head,
                CurrentUser => $args{'CurrentUser'},
                QueueObj    => $args{'Queue'},
            )
        ] if $RT::ParseNewMessageForTicketCcs;

        foreach my $base_type (qw(Requestor Cc AdminCc)) {
            foreach my $type (
                $base_type,
                "Add" . $base_type,
                $base_type . "s",
                "Add" . $base_type . "s" )
            {
                next unless exists $cmds{ lc $type };
                if ( $base_type =~ /^\Q$type\Es?$/ ) {
                    $create_args{ lc $base_type } = [ $cmds{ lc $type } ];
                } else {
                    push @{ $create_args{ lc $base_type } }, $cmds{ lc $type };
                }
            }
        }

        # get queue unless mail contain it
        $create_args{'Queue'} = $args{'Queue'}->Id unless exists $create_args{'Queue'};

        # subject
        unless ( $create_args{'Subject'} ) {
            $create_args{'Subject'} = $args{'Message'}->head->get('Subject');
            chomp $create_args{'Subject'};
        }

        # If we don't already have a ticket, we're going to create a new
        # ticket
        warn YAML::Dump( \%create_args );

        my ( $id, $txn_id, $msg ) = $ticket_as_user->Create( %create_args, MIMEObj => $args{'Message'} );
        unless ( $id ) {
            $RT::Logger->error("Couldn't create ticket, fallback to standard mailgate: $msg");
            return ($args{'CurrentUser'}, $args{'AuthLevel'});
        }

        # now that we've created a ticket, we abort so we don't create another.
        $args{'Ticket'}->Load($id);
        return ( $args{'CurrentUser'}, -1 );

    }
}

sub _SetAttribute {
    my $ticket    = shift;
    my $attribute = shift;
    my $value     = shift;
    my $results   = shift;
    my $setter    = "Set$attribute";
    my ( $val, $msg ) = $ticket->$setter($value);
    $results->{$attribute} = {
        value   => $value,
        result  => $val,
        message => $msg
    };

}
1;

sub _SetWatcherAttribute {
    my $ticket    = shift;
    my $method    = shift;
    my $attribute = shift;
    my $type      = shift;
    my $email     = shift;
    my $results   = shift;
    my ( $val, $msg ) = $ticket->DelWatcher(
        Type  => $type,
        Email => $email
    );

    $results->{$attribute} = {
        value   => $email,
        result  => $val,
        message => $msg
    };

}



sub _ReportResults {
    my $report = shift;
    my $recipient = shift;

    my $report_msg = '';

    foreach my $key (keys %$report) {
#        $report_msg .= $key.":".$report->{$key}->{'value'};
    }


}
1;
