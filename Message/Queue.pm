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
use base qw(Message);
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
                               "send_after"    => 1,
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
    $args -> {"format"} = "text";

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

            $self -> {"logger"} -> log("messaging", 0, undef, "Queued message $msgid with recipient $recip");
        }

    # Otherwise there is one message with multiple recipients.
    } else {
        my $msgid = $self -> _queue_message($args)
                or return undef;

        foreach my $recip (@{$args -> {"recipients"}}) {
            $self -> _add_recipient($msgid, $recip)
                or return undef;
        }

        $self -> {"logger"} -> log("messaging", 0, undef, "Queued message $msgid with recipients ".join(",", @{$args -> {"recipients"}}));
    }

    return 1;
}


## @method $ delete_message(%args)
# Delete a message from the queue. This will actually mark the message as deleted,
# messages are never really removed, they are simply marked as deleted. Note that
# this will deleted the message in a way that it will no longer be visible to either
# sender or recipient, and it will not be sent via external transports should any
# be in use. Supported arguments are:
#
# - userid The ID of the user deleting the message. If undef, it is assumed the
#          system is deleting the message.
# - id     The ID of the message to delete. This will delete only this one message
#          from the queue.
# - ident  A message ident to search for and delete any messages that have it set.
#          This allows a group of messages to be deleted in one go.
#
# @note This function will not mark messages as deleted if they have been sent or
#       viewed by a recipient. Only unsent, unviewed messages may be deleted.
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
        return $self -> _delete_by_id($args -> {"id"}, $args -> {"userid"}, $now);
    } elsif($args -> {"ident"}) {
        return $self -> _delete_by_ident($args -> {"ident"}, $args -> {"userid"}, $now);
    }

    return $self -> self_error("No id or ident passed to delete_message()");
}


## @method $ sender_delete_message($senderid, $messageid, $queuedelete)
# Allow the sender of a message to delete it. Normally this will simply delete the message
# from the sender's message list view (ie: it marks their view of the message as deleted),
# if 'queuedelete' is true, and the message has not been sent or viewed, this will
# delete the message in the message queue as well. Note, as with other delete methods,
# this does not actually remove the message from the queue, it is simply marked as deleted.
#
# @param senderid    The ID of the message sender.
# @param messageid   The ID of the message to delete.
# @param queuedelete If true, the message in the queue is marked as deleted as well as
#                    in the sender's view.
# @return true on success, undef on error.
sub sender_delete_message {
    my $self        = shift;
    my $senderid    = shift;
    my $messageid   = shift;
    my $queuedelete = shift;

    $self -> clear_error();

    $self -> {"logger"} -> log("messaging", $senderid, undef, "Deleting sender view of message $messageid");

    # It's always possible to delete the message from the sender's view unless it is already so
    my $nukeh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"message_sender"}."`
                                             SET deleted = UNIX_TIMESTAMP()
                                             WHERE message_id = ?
                                             AND sender_id = ?
                                             AND deleted IS NULL");
    my $result = $nukeh -> execute($messageid, $senderid);
    return $self -> self_error("Unable to perform sender message delete: ". $self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Sender message delete failed, no rows updated") if($result eq "0E0");

    if($queuedelete) {
        my $count = $self -> delete_message(id => $messageid,
                                            userid => $senderid);
        return undef if(!defined($count));
    }

    return 1;
}


## @method $ recipient_delete_message($recipientid, $messageid)
# Allow an individual recipient of a message to mark it as deleted in their view. This can
# be done regardless of the message status.
#
# @param recipientid The ID of the recipient user.
# @param messageid   The ID of the message to mark as deleted.
# @return true on success, undef on error.
sub recipient_delete_message {
    my $self        = shift;
    my $recipientid = shift;
    my $messageid   = shift;

    $self -> clear_error();

    $self -> {"logger"} -> log("messaging", $recipientid, undef, "Deleting recipient view of message $messageid");

    my $nukeh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"message_recipients"}."`
                                             SET deleted = UNIX_TIMESTAMP()
                                             WHERE message_id = ?
                                             AND recipient_id = ?
                                             AND deleted IS NULL");
    my $result = $nukeh -> execute($messageid, $recipientid);
    return $self -> self_error("Unable to perform recipient message delete: ". $self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Recipient message delete failed, no rows updated") if($result eq "0E0");

    return 1;
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

    my $messages = $self -> _get_by_fields([{field => "id", op => "=", value => $messageid}], $permit_deleted)
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

    return $self -> _get_by_fields([{field => "message_ident", op => "=", value => $ident}], $permit_deleted);
}


## @method $ get_sendable_messages($transportid, $include_failed)
# Fetch a list of all messages that can be sent at this time by the specified transport.
# This will look up all messages with a send_after that is less than or equal to the
# current time that have not yet been sent.
#
# @param transportid    The ID of the transport requesting sendable messages.
# @param include_failed If true, messages that have failed are included in the
#                       list of returned messages.
# @return A reference to an array of hashrefs on success, undef on error. Note that
#         if there are no matching messages, this returns a reference to an empty array.
sub get_sendable_messages {
    my $self           = shift;
    my $transportid    = shift;
    my $include_failed = shift;

    my $transport

    # Sendable messages are messsages that have a send_after field value less than the current
    # time, and a status of "pending" (or "failed") for the specified transport....
    my $sendh = $self -> {"dbh"} -> prepare("SELECT m.id
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"message_queue"}."` AS m,
                                                  `".$self -> {"settings"} -> {"database"} -> {"message_status"}."` AS s
                                             WHERE s.message_id = m.id
                                             AND s.transport_id = ?
                                             AND m.deleted IS NULL
                                             AND m.send_after < UNIX_TIMESTAMP() ".
                                            ($include_failed ? "AND (s.status = 'pending' OR s.status = 'failed') "
                                                             : "AND s.status = 'pending'"));
    $sendh -> execute($transportid)
        or return $self -> self_error("Unable to perform message transport lookup: ". $self -> {"dbh"} -> errstr);

    my $results = [];
    while(my $mid = $sendh -> fetchrow_arrayref()) {
        my $message = $self -> get_message($mid -> [0])
            or return undef;

        push(@{$results}, $message);
    }

    return $results;
}


# ============================================================================
#  Delivery

## @method $ deliver_queue($try_failed)
# Attempt to deliver queued messages that have not yet been sent. This will invoke
# the transport modules in turn, fetching sendable messages and trying to send them
#
# @param try_failed If this is set to true, transport modules will try to resend
#                   messages that previously failed to send.
sub deliver_queue {
    my $self       = shift;
    my $try_failed = shift;

    $self -> {"logger"} -> log("messaging", 0, undef, "Starting queue delivery");

    # Keep some counters...
    my $counts = { "transports" => 0,
                   "messages"   => 0,
                   "success"    => 0,
    };

    # Go through the list of transports, fetching the messages that can be sent by
    # that transport and try to send them.
    my $transports = $self -> get_transports();
    foreach my $transport (@{$transports}) {
        ++$counts -> {"transports"};

        my $messages = $self -> get_sendable_messages($transport -> {"id"}, $try_failed)
            or return undef;

        if(scalar(@{$messages})) {
            $counts -> {"messages"} += scalar(@{$messages});

            # Load the transport...
            $transport -> {"module"} = $self -> load_transport_module(id => $transport -> {"id"})
                or return $self -> self_error("Transport loading failed: ".$self -> {"errstr"});

            # Try to deliver each sendable message
            foreach my $message (@{$messages}) {
                my $sent = $transport -> {"module"} -> deliver($message);

                ++$counts -> {"success"} if($sent);

                # Store the send status for this transport
                $self -> update_status($message -> {"id"},
                                       $transport -> {"id"},
                                       $sent ? "sent" : "failed",
                                       $sent ? undef : $transport -> {"module"} -> {"errstr"})
                    or return undef;
            }
        }
    }
    $self -> {"logger"} -> log("messaging", 0, undef, "Queue delivery finished, processed ".$counts -> {"messages"}." through ".$counts -> {"transports"}." transports. ".$counts -> {"success"}." messages sent, ".($counts -> {"messages"} - $counts -> {"success"})." failed.");
}


# ============================================================================
#  Marking of various sorts

## @method $ update_status($messageid, $transportid, $status, $message)
# Update the status of the specified message for the specified transport, setting
# its status message if needed.
#
# @param messageid   The ID of the message to update.
# @param transportid The ID of the transport setting the status.
# @param status      The status to set the message to. Must be "pending", "sent", or "failed"
# @param message     Optional message status, may be undef.
# @return true on success, undef on error.
sub update_status {
    my $self        = shift;
    my $messageid   = shift;
    my $transportid = shift;
    my $status      = shift;
    my $message     = shift;

    $self -> clear_error();

    $status = "pending" unless($status eq "sent" || $status eq "failed");

    $self -> {"logger"} -> log("messaging", 0, undef, "Updating status of $messageid for transport $transportid: $status [".($message || "No status message")."]");

    my $stateh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"message_status"}."`
                                             SET status_time = UNIX_TIMESTAMP(), status = ?, status_message = ?
                                             WHERE message_id = ?
                                             AND transport_id = ?");
    my $result = $stateh -> execute($status, $message, $messageid, $transportid);
    return $self -> self_error("Unable to perform message status update: ". $self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Message status update failed, no rows updated") if($result eq "0E0");

    return 1;
}


## @method $ mark_recipient_read($messageid, $recipientid)
# Mark the specified message as read by the recipient. This allows local transports or
# other services that may be able to detect when a user opens a message to record the
# user having read the message.
#
# @param messageid   The ID of the message the recipient is reading.
# @param recipientid The ID of the recipient reading the message.
# @return true on success, undef on error.
sub mark_recipient_read {
    my $self        = shift;
    my $messageid   = shift;
    my $recipientid = shift;

    $self -> clear_error();

    $self -> {"logger"} -> log("messaging", $recipientid, undef, "Marking $messageid as read");

    my $stateh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"message_recipients"}."`
                                              SET viewed = UNIX_TIMESTAMP()
                                              WHERE message_id = ?
                                              AND recipient_id = ?");
    my $result = $stateh -> execute($messageid, $recipientid);
    return $self -> self_error("Unable to perform recipient view update: ". $self -> {"dbh"} -> errstr) if(!$result);
    return $self -> self_error("Message recipient view failed, no rows updated") if($result eq "0E0");

    return 1;

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

    # Add the sender data if possible
    if($args -> {"userid"}) {
        $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"message_sender"}."`
                                             (message_id, sender_id) VALUES(?, ?)");
        $result = $newh -> execute($msgid, $args -> {"userid"});
        return $self -> self_error("Unable to perform message sender insert: ". $self -> {"dbh"} -> errstr) if(!$result);
        return $self -> self_error("Message sender insert failed, no rows inserted") if($result eq "0E0");
    }

    # Now add transport status entries for each available transport
    $newh = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"message_status"}."`
                                         (message_id, transport_id, status_time) VALUES(?, ?, ?)");

    my $transports = $self -> get_transports();
    foreach my $transport (@{$transports}) {
        $result = $newh -> execute($msgid, $transport -> {"id"}, $args -> {"now"});
        return $self -> self_error("Unable to perform message transport status insert: ". $self -> {"dbh"} -> errstr) if(!$result);
        return $self -> self_error("Message transport status insert failed, no rows inserted") if($result eq "0E0");
    }

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


## @method private $ _delete_by_ident($ident, $userid, $deleted);
# Delete messages with the specified message ident. This may delete zero or more
# messages, and will not delete messages that have been sent or viewed.
#
# @param ident   Messages with this message ident will be deleted.
# @param userid    The user performing the delete. May be undef.
# @param deleted   The timestamp to place in the deleted field.
# @return The number of messages deleted (which may be zero) on success, undef
#         on error.
sub _delete_by_ident {
    my $self    = shift;
    my $ident   = shift;
    my $userid  = shift;
    my $deleted = shift;

    $self -> clear_error();

    $self -> {"logger"} -> log("messaging", $userid || 0, undef, "Attempting delete of messages with ident $ident");

    my $messh = $self -> {"dbh"} -> prepare("SELECT id
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"message_queue"}."`
                                             WHERE message_ident = ?");
    $messh -> execute($ident)
        or return $self -> self_error("Unable to perform message ident lookup: ". $self -> {"dbh"} -> errstr);

    my $deletecount = 0;
    while(my $msgid = $messh -> fetchrow_arrayref()) {
        my $result = $self -> _delete_by_id($msgid -> [0], $userid, $deleted);
        return undef if(!defined($result));

        $deletecount += $result;
    }

    return $deletecount;
}


## @method private $ _delete_by_id($messageid, $userid, $deleted)
# Attempt to delete the message with the specified message id.
# Note that this *does not* remove the message from the table, it simply marks
# it as deleted so that get_message() will not normally return it. This will not
# delete messages that have been sent or viewed.
#
# @param messageid The ID of the message to delete.
# @param userid    The user performing the delete. May be undef.
# @param deleted   The timestamp to place in the deleted field.
# @return 1 of the message is deleted, 0 if the message can not be deleted
#         because it has been sent or viewed, undef on error.
sub _delete_by_id {
    my $self      = shift;
    my $messageid = shift;
    my $userid    = shift;
    my $deleted   = shift;

    $self -> clear_error();

    $self -> {"logger"} -> log("messaging", $userid || 0, undef, "Attempting delete of message $messageid");

    # Check that the message has no views
    my $viewh = $self -> {"dbh"} -> prepare("SELECT COUNT(*)
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"message_recipients"}."`
                                             WHERE message_id = ?
                                             AND viewed IS NOT NULL");
    $viewh -> execute($messageid)
        or return $self -> self_error("Unable to perform message $messageid view check: ". $self -> {"dbh"} -> errstr);

    my $views = $viewh -> fetchrow_arrayref()
        or return $self -> self_error("Unable to obtain message $messageid view count. This should not happen!");

    # If the view count is non-zero, the message can not be deleted.
    return 0 if($views -> [0]);

    # Check that the message has not been sent
    my $senth = $self -> {"dbh"} -> prepare("SELECT COUNT(*)
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"message_status"}."`
                                             WHERE message_id = ?
                                             AND status = 'sent'");

    $senth -> execute($messageid)
        or return $self -> self_error("Unable to perform message $messageid sent check: ". $self -> {"dbh"} -> errstr);

    my $sent = $senth -> fetchrow_arrayref()
        or return $self -> self_error("Unable to obtain message $messageid sent count. This should not happen!");

    # If the sent count is non-zero, the message can not be deleted.
    return 0 if($sent -> [0]);

    $self -> {"logger"} -> log("messaging", $userid || 0, undef, "Delete of message $messageid passed view and sent check");

    # Otherwise, nobody is marked as having seen the message, if it hasn't been sent, mark it as deleted
    my $nukeh = $self -> {"dbh"} -> prepare("UPDATE `".$self -> {"settings"} -> {"database"} -> {"message_queue"}."`
                                             SET deleted = ?, deleted_id = ?
                                             WHERE id = ?
                                             AND deleted IS NULL");
    my $result = $nukeh -> execute($deleted, $userid, $messageid);
    return $self -> self_error("Unable to perform message delete: ". $self -> {"dbh"} -> errstr) if(!$result);

    $self -> {"logger"} -> log("messaging", $userid || 0, undef, "Delete of message $messageid row updated count: $result");

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

    my $sendh = $self -> {"dbh"} -> prepare("SELECT *
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"message_sender"}."`
                                              WHERE message_id = ?");

    my $reciph = $self -> {"dbh"} -> prepare("SELECT *
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"message_recipients"}."`
                                              WHERE message_id = ?");

    my $statush = $self -> {"dbh"} -> prepare("SELECT *
                                               FROM `".$self -> {"settings"} -> {"database"} -> {"message_status"}."`
                                               WHERE message_id = ?");

    $fetch -> execute(@fetch_bind)
        or return $self -> self_error("Unable to perform message lookup: ". $self -> {"dbh"} -> errstr);

    while(my $message = $fetch -> fetchrow_hashref()) {
        # Fetch the message sender info
        $sendh -> execute($message -> {"id"})
            or return $self -> self_error("Unable to perform message ".$message -> {"id"}." sender lookup: ". $self -> {"dbh"} -> errstr);

        # This fetch may return undef, which is fine - sender is not a required field
        $message -> {"sender"} = $sendh -> fetchrow_hashref();

        # Fetch the message recipients, and store the list in the message
        $reciph -> execute($message -> {"id"})
            or return $self -> self_error("Unable to perform message ".$message -> {"id"}." recipient lookup: ". $self -> {"dbh"} -> errstr);

        $message -> {"recipients"} = [];
        while(my $recipient = $reciph -> fetchrow_hashref()) {
            push(@{$message -> {"recipients"}}, $recipient);
        }

        # Messages must have at least one recipient, or they are broken
        return $self -> self_error("Message ".$message -> {"id"}." has no recorded recipients. This should not happen.")
            if(!scalar(@{$message -> {"recipients"}}));

        # fetch and store the status values for each transport
        $statush -> execute($message -> {"id"})
            or return $self -> self_error("Unable to perform message ".$message -> {"id"}." sender lookup: ". $self -> {"dbh"} -> errstr);

        $message -> {"status"} = {};
        while(my $status = $statush -> fetchrow_hashref()) {
            $message -> {"status"} -> {$status -> {"transport_id"}} = $status
        }

        push(@{$results}, $message);
    }

    return $results;
}


1;
