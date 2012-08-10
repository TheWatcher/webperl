## @file
# This file contains the implementation of the Message queue class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class Message::Queue
# This class allows messages to be added to the message queue, or retrieved from
# it in a format suitable for passing to Message::Sender.
#
#
package Message::Queue;
use strict;
use base qw(SystemModule);
use Utils qw(hash_or_hashref);


# ============================================================================
#  Constructor

## @cmethod Message::Queue new(%args)
# Create a new Message::Queue object. This will create an Message::Queue object
# that may be used to store messages to send at a later date, retrieve those
# messages in a form that can be passed to Message::Sender::send_message(), or
# mark messages in the queue as deleted.
#
# @param args A hash of arguments to initialise the Message::Queue object with.
# @return A new Message::Queue object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    # Define fields the user is allowed to search on in _get_by_field()
    $self -> {"get_fields"} = {"id"            => 1,
                               "created"       => 1,
                               "creator_id"    => 1,
                               "deleted"       => 1,
                               "deleted_id"    => 1,
                               "message_ident" => 1,
                               "status"        => 1,
                               "send_after"    => 1,
                               "sent_time"     => 1,
                               "error_message" => 1
    };

    return $self;
}


# ============================================================================
#  Addition and deletion

# Note: no editing. If messages need to be revised, they should be deleted and a
#       new message queued.

## @method $ queue_message($args)
# Add a message to the message queue. This will add a message to the queue table,
# ready to be sent at a later time by Message::Sender. The supported arguments are
# as follows:
#
# - subject (required) The email subject.
# - message (required) The body content to show in the email.
# - recipients (required) A reference to an array of userids. Each user will recieve
#       a copy of the message. If unique_recip is not set, the recipients may be
#       visible to each other under some transports.
# - unique_recip (optional) If set, copy of the message is made for each recipient,
#       with one recipient per message (defaults to false).
# - ident (optional) Allow a user-definable identifier string to be attached to
#       the message in the queue (if unique_recip is set, and more than one recipient
#       is specified, the ident is set in each copy of the message).
# - userid (optional) Contains the ID of the user adding this message. If this is
#       undef, the message is recorded as a system-generated one. Note that the
#       interpretation of this field is controlled by Message::Sender - it may
#       be used to determine the From: address, or it may be ignored.
# - send_after (optional) Specify the unix timestamp at which the message should be
#       sent. If this is not specified, the creation time is used.
# - delay (optional) If specified, this introduces a delay, specified in seconds,
#       between the message beng added and the first point at which it may be
#       sent. Note that, if both this and send_after are specified, the delay is
#       added to the value specified in send_after.
#
# @param args A hash, or a reference to a hash, of arguments defining the message.
# @return true on success, undef on error.
sub queue_message {
    my $self = shift;
    my $args = hash_or_hashref(@_);
    $args -> {"now"}  = time();

    $self -> clear_error();

    # Sort out the send time, based on possible user specified send time and delay
    $args -> {"send_after"} = $args -> {"now"} unless($args -> {"send_after"});
    $args -> {"send_after"} += $args -> {"delay"} if($args -> {"delay"});

    # FUTURE: potentially support other formats here. See also: https://www.youtube.com/watch?v=JENdgiAPD6c however.
    $args -> {"format"} = "plain";

    # Force required fields
    return $self -> self_error("Email subject not specified") unless($args -> {"subject"});
    return $self -> self_error("Email body not specified") unless($args -> {"message"});
    return $self -> self_error("No recipients specified")
        unless($args -> {"recipients"} && (ref($args -> {"recipients"}) eq "ARRAY") && scalar(@{$args -> {"recipients"}}));

    # If unique recipients are set, each recipient gets a copy of the message
    if($args -> {"unique_recip"}) {
        foreach my $recip (@{$args -> {"recipients"}}) {
            my $msgid = $self -> _queue_message($args)
                or return undef;

            $self -> _add_recipient($msgid, $recip)
                or return undef;
        }

    # Otherwise there is one message with multiple recipients.
    } else {
        my $msgid = $self -> _queue_message($args)
                or return undef;

        foreach my $recip (@{$args -> {"recipients"}}) {
            $self -> _add_recipient($msgid, $recip)
                or return undef;
        }
    }

    return 1;
}


## @method $ delete_message(%args)
# Delete a message from the queue. This will actually mark the message as deleted,
# messages are never really removed. Supported arguments are:
#
# - userid The ID of the user deleting the message. If undef, it is assumed the
#          system is deleting the message.
# - id     The ID of the message to delete. This will delete only this one message
#          from the queue.
# - ident  A message ident to search for and delete any messages that have it set.
#          This allows a group of messages to be deleted in one go.
#
# @param args A hash, or reference to a hash, of arguments specifying the message
#             to delete.
# @return The number of messages deleted on success (which maybe 0!), undef on error.
sub delete_message {
    my $self = shift;
    my $args = hash_or_hashref(@_);
    my $now  = time();

    $self -> clear_error();

    if($args -> {"id"}) {
        return $self -> _delete_by_field("id", $args -> {"id"}, $args -> {"userid"}, $now);
    } elsif($args -> {"ident"}) {
        return $self -> _delete_by_field("ident", $args -> {"ident"}, $args -> {"userid"}, $now);
    }

    return $self -> self_error("No id or ident passed to delete_message()");
}


# ============================================================================
#  Retrieval

## @method $ get_message($messageid, $permit_deleted)
# Fetch the data for an individual message. This will retrieve the message data, and
# the list of recipients of the message, and return the data in a hashref.
#
# @param messageid      The ID of the message to fetch the data for.
# @param permit_deleted If true, deleted messages may be fetched as well. This should
#                       not be set in most cases!
# @return A reference to a hash containing the message data on success, undef
#         otherwise.
sub get_message {
    my $self           = shift;
    my $messageid      = shift;
    my $permit_deleted = shift;

    $self -> clear_error();

    my $messages = $self -> _get_by_fields([{"id", "=", $messageid}], $permit_deleted)
        or return undef;

    return $self -> self_error("Unable to locate message $messageid: message does not exist")
        if(!scalar(@{$messages}));

    return $messages -> [0];
}


## @method $ get_messages($ident, $permit_deleted)
# Fetch zero or more messages based on their message ident. This retrieves the data
# for all messages that have the specified message ident, and returns the data as
# a refernece to an array of message hashrefs.
#
# @param ident          The message ident to search for.
# @param permit_deleted If true, deleted messages may be fetched as well. This should
#                       not be set in most cases!
# @return A reference to an array of hashrefs on success, undef on error. Note that
#         if there are no matching messages, this returns a reference to an empty array.
sub get_messages {
    my $self           = shift;
    my $ident          = shift;
    my $permit_deleted = shift;

    return $self -> _get_by_fields([{"message_ident", "=", $ident}], $permit_deleted);
}


## @method $ get_sendable_messages($include_failed)
# Fetch a list of all messages that can be sent at this time. This will look up all
# messages with a send_after that is less than or equal to the current time that
# have not yet been sent.
#
# @param include_failed If true, messages that have failed are included in the
#                       list of returned messages.
# @return A reference to an array of hashrefs on success, undef on error. Note that
#         if there are no matching messages, this returns a reference to an empty array.
sub get_sendable_messages {
    my $self           = shift;
    my $include_failed = shift;
    my $fieldspec = [ { "send_after", "<=", time() } ];

    if($include_failed) {
        push(@{$fieldspec}, {"orgroup" => [ { "status", "=", "pending" }, { "status", "=", "failed" } ]});
    } else {
        push(@{$fieldspec}, {"status", "=", "pending" } );
    }

    return $self -> _get_by_fields($fieldspec);
}


# ============================================================================
#  Ghastly internals

## @method private $ _queue_message($args)
# Add a message row in the queue table. This creates a new message row, and
# returns its row ID if successful.
#
# @param args A reference to a hash containing the message data.
# @return The new message id on success, undef on error.
sub _queue_message {
    my $self = shift;
    my $args = shift;

    $self -> clear_error();

    # Okay, give it a go...
    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"message_queue"}."`
                                            (created, creator_id, message_ident, subject, body, format, send_after)
                                            VALUES(?, ?, ?, ?, ?, ?, ?)");
    my $result = $newh -> execute($args -> {"now"}, $args -> {"userid"}, $args -> {"ident"}, $args -> {"subject"}, $args -> {"message"}, $args -> {"format"}, $args -> {"send_after"});
    return $self -> self_error("Unable to perform message insert: ". $self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Message insert failed, no rows inserted") if($result eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    my $msgid = $self -> {"dbh"} -> {"mysql_insertid"}
        or return $self -> self_error("Unable to obtain new message id");

    return $msgid;
}


## @method private $ _add_recipient($messageid, $recipientid)
# Add a message recipient. This creates a new recipient row, associating the
# specified recipient userid with a message.
#
# @param messageid   The ID of the message to add a recipient to.
# @param recipientid The ID of the user who should recieve the message.
# @return true on success, undef on error.
sub _add_recipient {
    my $self        = shift;
    my $messageid   = shift;
    my $recipientid = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"message_recipients"}."`
                                            (message_id, recipient_id)
                                            VALUES(?, ?)");
    my $result = $newh -> execute($messageid, $recipientid);
    return $self -> self_error("Unable to perform recipient addition: ". $self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Recipient addition failed, no rows inserted") if($result eq "0E0");

    return 1;
}


## @method private $ _delete_by_field($field, $value, $userid, $deleted)
# Attempt to delete messages where the specified field contains the value given.
# Note that this *does not* remove the message from the table, it simply marks
# it as deleted so that get_message() will not normally return it.
#
# @param field   The database table field to search for messages on.
# @param value   When a given message has this value in the specified field, it is
#                marked as deleted (aleady deleted messages are not changed)
# @param userid  The user performing the delete. May be undef.
# @param deleted The timestamp to place in the deleted field.
# @return The number of rows deleted.
sub _delete_by_field {
    my $self    = shift;
    my $field   = shift;
    my $value   = shift;
    my $userid  = shift;
    my $deleted = shift;

    $self -> clear_error();

    # Force valid field
    $field = "id" unless($field && ($field eq "id" || $field eq "message_ident"));

    my $nukeh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"message_queue"}."`
                                             SET deleted = ?, deleted_id = ?
                                             WHERE $field = ?
                                             AND deleted IS NULL");
    my $result = $nukeh -> execute($deleted, $userid, $value);
    return $self -> self_error("Unable to perform message delete: ". $self -> {"dbh"} -> errstr) if(!$result);

    # Result should contain the number of rows updated.
    return 0 if($result eq "0E0"); # need a special case for the zero rows, just in case...
    return $result;
}


## @method private $ _where_field($field, $bindarray)
# A utility function to make the where clause calculation in _get_by_fields() less horrible.
# This constructs a where clause expression (field op placeholder) and inserts a value
# into the bind array if needed.
#
# @param field     A reference to a hash containing the field, operation, and value.
# @param bindarray A reference to an array to store bind values in.
# @return A string containing the where clause expression.
sub _where_field {
    my $self      = shift;
    my $field     = shift;
    my $bindarray = shift;

    # fix up the field and op if needed
    $field -> {"field"} = "id" unless($self -> {"get_fields"} -> {$field -> {"field"}});
    $field -> {"op"}    = "="  unless($field -> {"op"} && ($field -> {"op"} eq "=" ||
                                                           $field -> {"op"} =~ /^(NOT )? LIKE$/io ||
                                                           $field -> {"op"} =~ /^[<>!]=?$/io ||
                                                           $field -> {"op"} =~ /^IS( NOT)? NULL$/io));
    my $where = $field -> {"field"}." ".$field -> {"op"};

    if($field -> {"op"} !~ /^IS/) {
        $where .= " ?";
        push(@{$bindarray}, $field -> {"value"});
    }

    return $where;
}


## @method private $ _get_by_fields($fieldspec, $permit_deleted)
# Fetch zero or more messages based on the value in a specified field. This retrieves
# the data for all messages that have the specified value, and returns the data as
# a reference to an array of message hashrefs.
#
# @param fieldspec      A reference to an array of field hashes, each entry must contain
#                       three keys: field, op, and value. field names must appear in
#                       $self -> {"get_fields"}. Each entry is ANDed to the where clause,
#                       there is no support for OR
# @param permit_deleted If true, deleted messages may be fetched as well. This should
#                       not be set in most cases!
# @return A reference to an array of hashrefs on success (note that if there are no
#         matching messages, the array will be empty!), undef on error.
sub _get_by_fields {
    my $self           = shift;
    my $fieldspec      = shift;
    my $permit_deleted = shift;
    my $results = [];

    $self -> clear_error();

    my $fields = scalar(@{$fieldspec});
    return $self -> self_error("No fields specified in call to _get_by_fields()") if(!$fields);

    # Build the where clause
    my $where = "";
    my @fetch_bind;
    for(my $field = 0; $field < $fields; ++$field) {
        # If the field contains a group of expressions to OR together, process it
        if($fieldspec -> [$field] -> {"orgroup"}) {
            my $group = "";

            foreach my $grpfield (@{$fieldspec -> [$field] -> {"orgroup"}}) {
                $group .= "OR " if($group);
                $group .= $self -> _where_field($grpfield, \@fetch_bind);
            }

            $where .= $field ? "WHERE " : " AND ";
            $where .= "($group)";

        # Otherwise add the field on.
        } else {
            # Build the where clause fragment
            $where .= $field ? " AND " : "WHERE ";
            $where .= $self -> _where_field($fieldspec -> [$field], \@fetch_bind);
        }
    }

    # Prepare some queries...
    my $fetch = $self -> {"dbh"} -> prepare("SELECT *
                                             FROM  `".$self -> {"settings"} -> {"database"} -> {"message_queue"}."`
                                             $where".($permit_deleted ? "" : " AND deleted IS NULL"));

    my $reciph = $self -> {"dbh"} -> prepare("SELECT recipient_id
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"message_recipients"}."`
                                              WHERE message_id = ?");

    $fetch -> execute(@fetch_bind)
        or return $self -> self_error("Unable to perform message lookup: ". $self -> {"dbh"} -> errstr);

    while(my $message = $fetch -> fetchrow_hashref()) {
        $reciph -> execute($message -> {"id"})
            or return $self -> self_error("Unable to perform message ".$message -> {"id"}." recipient lookup: ". $self -> {"dbh"} -> errstr);

        $message -> {"recipients"} = [];
        while(my $recipient = $reciph -> fetchrow_arrayref()) {
            push(@{$message -> {"recipients"}}, $recipient -> [0]);
        }

        return $self -> self_error("Message ".$message -> {"id"}." has no recorded recipients. This should not happen.")
            if(!scalar(@{$message -> {"recipients"}}));

        push(@{$results}, $message);
    }

    return $results;
}


1;
