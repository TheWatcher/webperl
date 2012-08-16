## @file
# This file contains the implementation of the EMail Message Transport class.
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

## @class Message::Transport::Email
# This class implements the email transport system; lasciate ogne speranza, voi ch'intrate.
#
package Message::Transport::Email;
use strict;
use base qw(Message);
use Encode;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Email::Sender::Transport::SMTP::Persistent;
use Try::Tiny;

# ============================================================================
#  Constructor

## @cmethod Message::Transport::Email new(%args)
# Create a new Message::Transport::Email object. This will create an object
# that may be used to send messages to recipients over SMTP.
#
# @param args A hash of arguments to initialise the Message::Transport::Email
#             object with.
# @return A new Message::Transport::Email object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    # Make local copies of the config for readability
    # Arguments for Email::Sender::Transport::SMTP(::Persistent)
    $self -> {"host"}     = $self -> {"settings"} -> {"config"} -> {"Message::Transport::Email::smtp_host"};
    $self -> {"port"}     = $self -> {"settings"} -> {"config"} -> {"Message::Transport::Email::smtp_port"};
    $self -> {"ssl"}      = $self -> {"settings"} -> {"config"} -> {"Message::Transport::Email::smtp_secure"};
    $self -> {"username"} = $self -> {"settings"} -> {"config"} -> {"Message::Transport::Email::username"};
    $self -> {"password"} = $self -> {"settings"} -> {"config"} -> {"Message::Transport::Email::password"};

    # Should persistent SMTP be used?
    $self -> {"persist"}  = $self -> {"settings"} -> {"config"} -> {"Message::Transport::Email::persist"};

    # Should the sender be forced (ie: always use the system-specified sender, even if the message has
    # an explicit sender. This should be the address to set as the sender.
    $self -> {"force_sender"} = $self -> {"settings"} -> {"config"} -> {"Message::Transport::Email::force_sender"};

    # The address to use as the envelope sender.
    $self -> {"env_sender"}   = $self -> {"settings"} -> {"config"} -> {"Core:envelope_address"};

    # set up persistent STMP if needed
    if($self -> {"persist"}) {
        eval { $self -> {"smtp"} = Email::Sender::Transport::SMTP::Persistent -> new(host => $self -> {"host"},
                                                                                     port => $self -> {"port"},
                                                                                     ssl  => $self -> {"ssl"},
                                                                                     sasl_username => $self -> {"username"},
                                                                                     sasl_password => $self -> {"password"});
        };
        return SystemModule::set_error("SMTP Initialisation failed: $@") if($@);
    }

    return $self;
}


## @method void DESTROY()
# Destructor method to clean up persistent SMTP if it is in use.
sub DESTROY {
    my $self = shift;

    $self -> {"smtp"} -> disconnect()
        if($self -> {"persist"} && $self -> {"smtp"});
}


# ============================================================================
#  Delivery

## @method $ deliver($message)
# Attempt to deliver the specified message to its recipients.
#
# @param message A reference to hash containing the message data.
# @return True on success, undef on failure/error.
sub deliver {
    my $self    = shift;
    my $message = shift;

    if(!$self -> {"persist"}) {
        eval { $self -> {"smtp"} = Email::Sender::Transport::SMTP -> new(host => $self -> {"host"},
                                                                         port => $self -> {"port"},
                                                                         ssl  => $self -> {"ssl"},
                                                                         sasl_username => $self -> {"username"},
                                                                         sasl_password => $self -> {"password"});
        };
        return $self -> self_error("SMTP Initialisation failed: $@") if($@);
    }

    my ($from, $to) = ($self -> {"env_sender"}, "");

    # Work out the the sender if needed...
    if(!$self -> {"force_sender"} && $message -> {"sender"}) {
        $from = $self -> _get_user_email($message -> {"sender"} -> {"sender_id"})
            or return undef;
    }

    # And the recipients
    foreach my $recipient (@{$message -> {"recipients"}}) {
        my $recip = $self -> _get_user_email($recipient -> {"recipient_id"})
            or return undef;

        $to .= "," if($to);
        $to .= $recip;
    }

    my $email = Email::MIME -> create(header_str => [ From => $from,
                                                      To   => $to,
                                                      Subject => $message -> {"subject"}
                                                      ],
                                      body_str   => Encode::encode_utf8($message -> {"body"}),
                                      attributes => { charset => 'utf8',
                                                      content_type => "text/plain",
                                                      encoding => 'base64' });

    try {
        sendmail($email, { from => $self -> {"env_sender"},
                           transport => $self -> {"smtp"}});
    } catch {
        return $self -> self_error("Delivery of message ".$message -> {"id"}." failed: $_");
    };

    return 1;
}


# ============================================================================
#  Support code

## @method private $ _get_user_email($userid)
# Obtain the email address set for the specified user. This class may be called outside
# the normal application environment, so it might not have access to the AppUser or Session
# classes - but it still needs email addresses! This looks directly into the user table
# to obtain the address.
#
# @param userid The ID of the user to fetch the email address for.
# @return The user's email address on success, undef on error.
sub _get_user_email {
    my $self   = shift;
    my $userid = shift;

    my $userh = $self -> {"dbh"} -> prepare("SELECT email
                                             FROM ".$self -> {"settings"} -> {"database"} -> {"users"}."
                                             WHERE user_id = ?");
    $userh -> execute($userid)
        or return $self -> self_error("Unable to perform user email lookup: ". $self -> {"dbh"} -> errstr);

    my $user = $userh -> fetchrow_arrayref()
        or return $self -> self_error("User email lookup failed: user $userid does not exist");

    return $user -> [0];
}

1;
