package IO::Async::Loop::Epoll::FD;

use strict;
use warnings;

use parent 'IO::Async::Loop::Epoll';

use Carp 'croak';
use Linux::FD qw/timerfd signalfd/;
use Scalar::Util 'refaddr';
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

1;

# ABSTRACT: Use IO::Async with Epoll and special filehandles
