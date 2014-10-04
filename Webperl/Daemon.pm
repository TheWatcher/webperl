## @file
# This file contains the implementation of a daemoniser class.
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
# along with this program.  If not, see http://www.gnu.org/licenses/.

## @class
# A class to help with running a process as a daemon. This class is somewhere
# between Proc::Daemon and App::Daemon in that it provides a somewhat nicer
# interface to the daemonisation process than Proc::Daemon but doesn't come
# with App::Daemon's frankly ridiculous set of dependencies (seriously, why
# does it need Sysadm::Install?!)
package Webperl::Daemon;

use v5.12;
use base qw(Webperl::SystemModule);
use Carp qw(carp);
use File::Basename;
use POSIX;
use Proc::Daemon;
use Webperl::Utils qw(read_pid write_pid path_join);

use constant STATE_OK               => 0;
use constant STATE_DEAD_PID_EXISTS  => 1;
use constant STATE_NOT_RUNNING      => 3;
use constant STATE_ALREADY_RUNNING  => 100;
use constant STATE_SIGNAL_ERROR     => 101;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new daemon object. This should be called to create a new Daemon object
# that can be used to actually daemonise the process, or interrogate or stop an
# already running copy of it. This supports all the arguments supported by the
# constructor for Proc::Daemon except that:
#
# - `pid_file` should be replaced with `pidfile`.
# - `exec_command` is not supported and will be ignored.
#
# This class also supports:
#
# - `signal`: the signal to send to the daemon process when run() is called with
#   `stop` or `restart` as the action. This defaults to `TERM`.
# - `setuid`: this may be either a uid or a username, rather than just a uid.
#
# @param args The arguments to create the Daemon object with.
# @return A reference to a new Daemon object on success, undef on error.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(minimal => 1,
                                        signal  => "TERM",
                                        @_)
        or return undef;

    # Nuke any attempt at using Proc::Daemon's pid and command code
    $self -> {"pid_file"} = $self -> {"exec_command"} = undef;

    ($self -> {"script"}) = basename($0) =~ /^([-\w.]+)$/;
    return Webperl::SystemModule::set_error("Unable to determine script name")
        if(!$self -> {"script"});

    # Work out a default PID file if one has not been set.
    $self -> {"pidfile"} = path_join(".", $self -> {"script"}.".pid") if(!$self -> {"pidfile"});

    # convert username to uid if needed
    if(defined($self -> {"setuid"}) && $self -> {"setuid"} !~ /^\d+$/) {
        my $uid = (getpwnam($self -> {"setuid"}))[2];
        return Webperl::SystemModule::set_error("Unable to resolve uid for user '".$self -> {"setuid"}."'")
            if(!$uid);

        $self -> {"setuid"} = $uid;
    }

    return $self;
}


# ============================================================================
#  Daemonise code

## @method $ run($action)
# Perform the requested action.
#
# @param action The action to perform. Should be one of 'start', 'stop', 'status' or 'restart'
sub run {
    my $self   = shift;
    my $action = shift || "";

    # return status information if requested
    return $self -> running() ? STATE_OK : STATE_NOT_RUNNING
        if($action eq "status");

    # stop the existing daemon if stop or restart is needed.
    if($action eq "stop" || $action eq "restart") {

        # If the deamon isn't running, this can't do anything to stop it!
        if(!$self -> running()) {
            carp "WARNING: ".$self -> {"script"}." is already stopped";
            return STATE_OK if($action eq "stop");

        } else {

            # Try to kill the deamon, and if something goes wrong, or stop has been
            # requested directly, return the status code.
            my $state = $self -> kill_daemon();
            return $state if($action eq "stop" || $state != STATE_OK);
        }
    }

    # Start the daemon if it isn't already running
    if($self -> running()) {
        carp "WARNING: ".$self -> {"script"}." has already been started";
        return STATE_ALREADY_RUNNING;
    } else {
        return $self -> detach();
    }
}


## @method $ detach()
# Start the daemon process, storing the process ID of the daemon process in the
# pidfile if a path to one has been specified.
#
# @return STATE_OK if the daemon has been started, does not return on error.
sub detach {
    my $self = shift;

    my $daemon = Proc::Daemon -> new(%{$self});
    my $child_pid = $daemon -> Init();

    # Parent process does nothing, can finish here
    exit 0 if($child_pid);

    # Here on, it's the child process...
    # Write the current process ID to the pid file if needed
    write_pid($self -> {"pidfile"}) if($self -> {"pidfile"});

    return STATE_OK;
}


## @method $ running()
# Determine whether another instance of the script is running, and if it is
# return its process ID.
#
# @return The PID of the running process on success, 0 if the process is not
#         currently running. If the process is running, but this process does
#         not have permission to signal it, this returns the negative of the
#         PID.
sub running {
    my $self = shift;

    my $pid;
    if(-f $self -> {"pidfile"}) {
        eval { $pid = read_pid($self -> {"pidfile"}) };
        print $@ if($@);
    }
    return 0 if(!$pid);

    my $signalled = kill 0,$pid;
    $signalled ||= $!; # will either be 1 or an error code

    # process signalled successfully
    if($signalled == 1) {
        return $pid;

    # exists, but no permissions to signal it
    } elsif($signalled == EPERM) {
        return -1 * $pid;
    }

    return 0;
}


## @method $ kill_daemon()
# Halt the daemon process if it is currently running.
#
# @return STATE_OK if the daemon has been stopped (or was never running),
#         STATE_DEAD_PID_EXISTS if the process is still running but the
#         kill signal failed.
sub kill_daemon {
    my $self = shift;
    my $pid  = $self -> running();

    return STATE_OK if(!$pid);

    my $killed = kill($self -> {"signal"}, $pid);
    if($killed) {
        unlink($self -> {"pidfile"})
            if($self -> {"pidfile"} && -f $self -> {"pidfile"});

        return STATE_OK;
    }

    return STATE_DEAD_PID_EXISTS;
}


## @method $ send_signal($signal)
# Signal the running daemon with the specified signal.
#
# @param signal The signal to send to the daemon
# @return STATE_OK on success, STATE_NOT_RUNNING if the daemon is
#         not running, otherwise STATE_SIGNAL_ERROR.
sub send_signal {
    my $self   = shift;
    my $signal = shift;
    my $pid    = $self -> running();

    return STATE_NOT_RUNNING if(!$pid);

    my $sent = kill($signal, $pid);
    return STATE_OK if($sent);

    return STATE_SIGNAL_ERROR;
}

1;
