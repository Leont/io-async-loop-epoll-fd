package IO::Async::Loop::Epoll::FD;

use strict;
use warnings;

use parent 'IO::Async::Loop::Epoll';

use Carp 'croak';
use Linux::FD qw/timerfd signalfd/;
use Linux::FD::Pid;
use Scalar::Util qw/refaddr weaken/;
use Signal::Mask;

use constant _CAN_WATCH_ALL_PIDS => 0;

sub watch_signal {
	my ($self, $signal, $code) = @_;

	$code or croak "Expected 'code' as CODE ref";

	my $watch_signal = $self->{watch_signal} //= {};
	my $callback = sub {
		if (my $pair = $watch_signal->{$signal}) {
			my ($fh, $code) = @{$pair};
			while (my $info = $fh->receive) {
				$code->($info->{signo});
			}
		}
	};

	my $fh = signalfd($signal, 'non-blocking');
	$Signal::Mask{$signal} = !!1;
	$self->watch_io(handle => $fh, on_read_ready => $callback);

	$self->{watch_signal}{$signal} = [ $fh, $code ];
	return $signal;
}

sub unwatch_signal {
	my ($self, $id) = @_;
	if (my $pair = delete $self->{watch_signal}{$id}) {
		$self->unwatch_io(handle => $pair->[0]);
		$Signal::Mask{$id} = !!0;
	}
}

# This is crucial to prevent the default implementation from mucking around with signals
sub post_fork {
}

sub watch_time {
	my ($self, %params) = @_;

	my $code = $params{code} or croak "Expected 'code' as CODE ref";

	my $id;
	my $watch_time = $self->{watch_time} //= {};
	my $callback = sub {
		my $fh = $watch_time->{$id};
		$code->() if $fh && $fh->receive;
	};

	my $fh;
	if( defined $params{after} ) {
		my $after = $params{after} >= 0 ? $params{after} : 0;
		$fh = timerfd($params{clock} || 'monotonic', 'non-blocking');
		if ($after > 0) {
			$fh->set_timeout($after);
		} else {
			my $callback = sub {
				my $fh2 = $watch_time->{$id};
				$code->() if $fh2;
			};
			$self->watch_idle(code => $callback, when => 'later');
		}
	}
	else {
		$fh = Linux::FD::Timer->new($params{clock} || 'realtime', 'non-blocking');
		$fh->set_timeout($params{at}, 0, !!1);
	}

	$self->watch_io(handle => $fh, on_read_ready => $callback);

	$id = refaddr $fh;
	$self->{watch_time}{$id} = $fh;
	return $id;
}

sub unwatch_time {
	my ($self, $id) = @_;
	my $fh = delete $self->{watch_time}{$id};
	$self->unwatch_io(handle => $fh);
}

sub watch_process {
	my ($self, $process, $code) = @_;

	$code or croak "Expected 'code' as CODE ref";

	my $backref = $self;
	weaken $backref;
	my $callback = sub {
		if (my $pair = $backref->{watch_process}{$process}) {
			my ($fh, $code) = @{$pair};
			if (my $status = $fh->wait) {
				$code->($process, $status);
				$backref->unwatch_process($process);
			}
		}
	};

	my $fh = Linux::FD::Pid->new($process, 'non-blocking');
	$Signal::Mask{CHLD} ||= 1;
	$self->watch_io(handle => $fh, on_read_ready => $callback);

	$self->{watch_process}{$process} = [ $fh, $code ];
	return $process;
}

sub unwatch_process {
	my ($self, $id) = @_;
	if (my $pair = delete $self->{watch_process}{$id}) {
		$self->unwatch_io(handle => $pair->[0]);
		$Signal::Mask{CHLD} = 0 if not keys %{ $self->{watch_process} };
	}
}

1;

# ABSTRACT: Use IO::Async with Epoll and special filehandles

=head1 DESCRIPTION

This is a Linux specific backend for L<IO::Async|IO::Async>. Unlike L<IO::Async::Loop::Epoll|IO::Async::Loop::Epoll>, this will use signalfd for signal handling, timerfd for timer handling and pidfd for process handling.

=head1 SEE ALSO

=over 4

=item * L<IO::Async::Loop::Epoll|IO::Async::Loop::Epoll>

=back
