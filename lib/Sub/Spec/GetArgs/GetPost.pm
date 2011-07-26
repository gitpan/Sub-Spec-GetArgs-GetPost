package Sub::Spec::GetArgs::GetPost;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use JSON;
use PHP::Serialization;
use Plack::Request;
use Sub::Spec::Utils; # temp, for _parse_schema
use YAML::Syck;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(get_args_from_getpost);

our $VERSION = '0.01'; # VERSION

our %SPEC;

my $json = JSON->new->allow_nonref;

sub _parse_schema {
    Sub::Spec::Utils::_parse_schema(@_);
}

$SPEC{get_args_from_getpost} = {
    summary => 'Get subroutine arguments (%args) from HTTP GET/POST '.
        'request data',
    description_fmt => 'org',
    description => <<'_',

Using information in sub spec's ~args~ clause, parse HTTP GET/POST request data
into hash ~%args~, suitable for passing into subs.

Request data is retrieved from PSGI environment ($env).

Arguments can be put in query string (GET) or www-form (POST), e.g.
http://127.0.0.1:5000/Module/sub?arg1=val&arg2=val, or can also be encoded as
YAML/JSON/PHP and be put into request body with appropriate Content-Type header
(i.e. ~text/yaml~ when sending in YAML, ~application/json~ for JSON, and
~application/vnd.php.serialized~ for PHP serialization.

_
    args => {
        psgi_env => ['hash' => {
        }],
        spec => ['hash*' => {
        }],
        per_var_encoding => ['bool' => {
            summary => 'Whether to enable per-var encoding',
            description_fmt => 'org',
            description => <<'_',

If set to 1, each request variable can be appended by a ":F" notation to
indicate the encoding format that the variable is in, for example (in URL):

: http://127.0.0.1:5000/Module/sub?array_arg:j=%5B1%2C2%2C3%5D

After JSON decoding (:j indicates json), ~array_arg~ will contain an array ~[1,
2, 3]~.

_
            default => 1,
        }],
        accept_json => ['bool' => {
            summary => 'Whether to accept JSON as encoding format',
            default => 1,
        }],
        accept_yaml => ['bool' => {
            summary => 'Whether to accept YAML as encoding format',
            description => <<'_',

Currently Perl module YAML::Syck is used to encode/decode YAML.

_
            default => 1,
        }],
        accept_php => ['bool' => {
            summary => 'Whether to accept PHP serialization format as encoding',
            default => 1,
        }],
        allow_unknown_params => ['bool' => {
            summary => 'Whether to allow unknown parameters'.
                ' (that is, params not mentioned in args schema)',
            default => 0,
        }],
        exclude_params => ['str' => {
            summary => 'A regex to exclude parameters from checking',
        }],
    },
};
sub get_args_from_getpost {
    my %args = @_;

    my $per_var_encoding = $args{per_var_encoding} // 1;
    my $accept_json = $args{accept_json} // 1;
    my $accept_php  = $args{accept_php}  // 1;
    my $accept_yaml = $args{accept_yaml} // 1;
    my $allow_unknown_params = $args{allow_unknown_params} // 0;
    my $spec = $args{spec};
    return [400, "Please specify spec"] unless $spec;
    my $args_spec = $spec->{args} // {};
    my $psgi_env = $args{psgi_env};
    return [400, "Please specify psgi_env"] unless $psgi_env;
    my $exclude_params = $args{exclude_params};
    if (defined $exclude_params) {
        unless (ref($exclude_params) ne 'Regexp') {
            eval { $exclude_params = qr/$exclude_params/ };
            return [400, "Invalid exclude_params: invalid regex: $@"]
                if $@;
        }
    }

    my $ct = $psgi_env->{CONTENT_TYPE} // '';
    my $req = Plack::Request->new($psgi_env);

    my $args;
    if ($ct eq 'application/vnd.php.serialized') {
        $log->trace('Request is PHP');
        return [400, "PHP serialized data is not acceptable"]
            unless $accept_php;
        eval { $args = PHP::Serialization::unserialize($req->content) };
        return [400, "Invalid PHP serialized data in request body: $@"] if $@;
    } elsif ($ct eq 'text/yaml') {
        $log->trace('Request is YAML');
        return [400, "YAML data is not acceptable"] unless $accept_yaml;
        eval { $args = Load($req->content) };
        return [400, "Invalid YAML in request body: $@"] if $@;
    } elsif ($ct eq 'application/json') {
        $log->trace('Request is JSON');
        return [400, "JSON data is not acceptable"] unless $accept_json;
        eval { $args = $json->decode($req->content) };
        return [400, "Invalid JSON in request body: $@"] if $@;
    } else {
        $args = {};
        $log->trace('Request is www-form');
        # normal GET/POST, check each query parameter for :j, :y, :p decoding
        my @params = $req->param;
        for my $k (@params) {
            my $v = $req->param($k);
            if ($k =~ /(.+):j$/) {
                return [400, "JSON data is not acceptable (param $k)"]
                    unless $accept_json && $per_var_encoding;
                $k = $1;
                eval { $v = $json->decode($v) };
                return [400, "Invalid JSON in query parameter $k: $@"] if $@;
                $args->{$k} = $v;
            } elsif ($k =~ /(.+):y$/) {
                return [400, "YAML data is not acceptable (param $k)"]
                    unless $accept_yaml && $per_var_encoding;
                $k = $1;
                eval { $v = Load($v) };
                return [400, "Invalid YAML in query parameter $k: $@"] if $@;
                $args->{$k} = $v;
            } elsif ($k =~ /(.+):p$/) {
                return [400, "PHP serialized data is not acceptable (param $k)"]
                    unless $accept_php && $per_var_encoding;
                $k = $1;
                eval { $v = PHP::Serialization::unserialize($v) };
                return [400, "Invalid PHP serialized data ".
                            "in query parameter $k: $@"] if $@;
                $args->{$k} = $v;
            } else {
                $args->{$k} = $v;
            }
        }
    }

    # sanity check on args. XXX proper schema checking.
    $args //= {};
    return [400, "Invalid args, must be a hash"]
        unless ref($args) eq 'HASH';
    while (my ($k, $v) = each %$args) {
        next if $exclude_params && $k =~ $exclude_params;
        return [400, "Invalid param syntax $k, use WORD or WORD:{j,y,p}"]
            unless $k =~ /\A\w+\z/;
        return [400, "Unknown param $k"]
            unless $allow_unknown_params || $args_spec->{$k};
        # XXX check required arg?
    }

    #$log->tracef("args = %s", $args);
    [200, "OK", $args];
}

1;
#ABSTRACT: Get subroutine arguments from HTTP GET/POST request


=pod

=head1 NAME

Sub::Spec::GetArgs::GetPost - Get subroutine arguments from HTTP GET/POST request

=head1 VERSION

version 0.01

=head1 SYNOPSIS

 use Sub::Spec::GetArgs::GetPost;

 my $res = get_args_from_getpost(psgi_env=>$env, spec=>$spec, ...);

=head1 DESCRIPTION

This module provides get_args_from_getpost(), which parses HTTP GET/POST request
data into subroutine arguments (%args).

This module uses L<Log::Any> for logging framework.

This module's functions has L<Sub::Spec> specs.

=head1 FUNCTIONS

None are exported by default, but they are exportable.

=head2 get_args_from_getpost(%args) -> [STATUS_CODE, ERR_MSG, RESULT]


Get subroutine arguments (%args) from HTTP GET/POST request data.

Using information in sub spec's ~args~ clause, parse HTTP GET/POST request data
into hash ~%args~, suitable for passing into subs.

Request data is retrieved from PSGI environment ($env).

Arguments can be put in query string (GET) or www-form (POST), e.g.
http://127.0.0.1:5000/Module/sub?arg1=val&arg2=val, or can also be encoded as
YAML/JSON/PHP and be put into request body with appropriate Content-Type header
(i.e. ~text/yaml~ when sending in YAML, ~application/json~ for JSON, and
~application/vnd.php.serialized~ for PHP serialization.

Returns a 3-element arrayref. STATUS_CODE is 200 on success, or an error code
between 3xx-5xx (just like in HTTP). ERR_MSG is a string containing error
message, RESULT is the actual result.

Arguments (C<*> denotes required arguments):

=over 4

=item * B<accept_json> => I<bool> (default C<1>)

Whether to accept JSON as encoding format.

=item * B<accept_php> => I<bool> (default C<1>)

Whether to accept PHP serialization format as encoding.

=item * B<accept_yaml> => I<bool> (default C<1>)

Whether to accept YAML as encoding format.

Currently Perl module YAML::Syck is used to encode/decode YAML.

=item * B<allow_unknown_params> => I<bool> (default C<0>)

Whether to allow unknown parameters (that is, params not mentioned in args schema).

=item * B<exclude_params> => I<str>

A regex to exclude parameters from checking.

=item * B<per_var_encoding> => I<bool> (default C<1>)

Whether to enable per-var encoding.

If set to 1, each request variable can be appended by a ":F" notation to
indicate the encoding format that the variable is in, for example (in URL):

: http://127.0.0.1:5000/Module/sub?array_arg:j=%5B1%2C2%2C3%5D

After JSON decoding (:j indicates json), ~array_arg~ will contain an array ~[1,
2, 3]~.

=item * B<psgi_env> => I<hash>

=item * B<spec>* => I<hash>

=back

=head1 FAQ

=head1 SEE ALSO

L<Sub::Spec>

L<Sub::Spec::HTTP::Server>

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


__END__

