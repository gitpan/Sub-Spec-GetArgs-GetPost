#!perl

use 5.010;
use strict;
use warnings;
use Log::Any '$log';
use Test::More 0.96;

#use Data::Clone qw(clone);
use HTTP::Request::Common;
use Plack::Test;
use Sub::Spec::GetArgs::GetPost qw(get_args_from_getpost);
use YAML::Syck;

my $spec = {
    args => {
        arg1 => ['str*' => {arg_pos=>0}],
        arg2 => ['str*' => {arg_pos=>1}],
        arg3 => 'str',
        arg4 => 'array',
        arg5 => 'hash',
        arg4b => 'array',
        arg4c => 'array',
    },
};

test_getargs(
    name => "GET",
    req  => (GET "/?arg1=v1&arg2=v2"),
    spec => $spec,
    res  => {arg1=>"v1", arg2=>"v2"},
);

test_getargs(
    name => "POST",
    req  => (POST "/", {arg1=>"v1", arg2=>"v2"}),
    spec => $spec,
    res  => {arg1=>"v1", arg2=>"v2"},
);

test_getargs(
    name   => "unknown var -> error 400",
    req    => (GET "/?arg1=v1&foo=v2"),
    status => 400,
    spec   => $spec,
);

test_getargs(
    name => "allow_unknown_params",
    allow_unknown_params => 1,
    req  => (GET "/?arg1=v1&foo=v2"),
    spec => $spec,
    res  => {arg1=>"v1", foo=>"v2"},
);

test_getargs(
    name => "exclude_params",
    exclude_params => qr/^fo+$/,
    req  => (GET "/?arg1=v1&foo=v2"),
    spec => $spec,
    res  => {arg1=>"v1", foo=>"v2"},
);

test_getargs(
    name   => "accept_yaml=0",
    accept_yaml => 0,
    req    => (POST "/", "Content-Type"=>"text/yaml", Content => "{arg4: v4}"),
    spec   => $spec,
    status => 400,
);
test_getargs(
    name   => "accept_yaml=1",
    spec   => $spec,
    req    => (POST "/", "Content-Type"=>"text/yaml", Content => "{arg4: v4}"),
    spec   => $spec,
    res    => {arg4=>"v4"},
);
test_getargs(
    name   => "invalid yaml -> error 400",
    spec   => $spec,
    req    => (POST "/", "Content-Type"=>"text/yaml", Content => "{arg4: v4"),
    spec   => $spec,
    status => 400,
);

test_getargs(
    name   => "sanity check on args: must be hash",
    spec   => $spec,
    req    => (POST "/", "Content-Type"=>"text/yaml", Content => "[arg4, v4]"),
    spec   => $spec,
    status => 400,
);

test_getargs(
    name   => "accept_json=0",
    accept_json => 0,
    req    => (POST "/", "Content-Type"=>"application/json",
               Content => '{"arg4":"v4"}'),
    spec   => $spec,
    status => 400,
);
test_getargs(
    name   => "accept_json=1",
    spec   => $spec,
    req    => (POST "/", "Content-Type"=>"application/json",
               Content => '{"arg4":"v4"}'),
    spec   => $spec,
    res    => {arg4=>"v4"},
);
test_getargs(
    name   => "invalid json -> error 400",
    spec   => $spec,
    req    => (POST "/", "Content-Type"=>"application/json",
               Content => '{"arg4":"v4}'),
    spec   => $spec,
    status => 400,
);

test_getargs(
    name   => "accept_php=0",
    accept_php => 0,
    req    => (POST "/", "Content-Type"=>"application/vnd.php.serialized",
               Content => 'a:1:{s:4:"arg4";s:2:"v4";}'),
    spec   => $spec,
    status => 400,
);
test_getargs(
    name   => "accept_php=1",
    spec   => $spec,
    req    => (POST "/", "Content-Type"=>"application/vnd.php.serialized",
               Content => 'a:1:{s:4:"arg4";s:2:"v4";}'),
    spec   => $spec,
    res    => {arg4=>"v4"},
);
test_getargs(
    name   => "invalid php -> error 400",
    spec   => $spec,
    req    => (POST "/", "Content-Type"=>"application/vnd.php.serialized",
               Content => 'a:1:{s:4:"arg4";s:2:"v4;}'),
    spec   => $spec,
    status => 400,
);

test_getargs(
    name   => "per_var_encoding=0",
    per_var_encoding => 0,
    req    => (GET "/?arg4:y=[v4]"),
    spec   => $spec,
    status => 400,
);
test_getargs(
    name   => "per_var_encoding=1",
    req    => (GET "/?arg4:y=[v4]&arg4b:j=%5B%22v4b%22%5D".
                   "&arg4c:p=a%3A1%3A%7Bi%3A0%3Bs%3A3%3A%22v4c%22%3B%7D"),
    spec   => $spec,
    res    => {arg4=>["v4"], arg4b=>["v4b"], arg4c=>["v4c"]},
);

test_getargs(
    name   => "yaml error in query parameter -> error 400",
    req    => (GET "/?arg4:y=[v4"),
    spec   => $spec,
    status => 400,
);
test_getargs(
    name   => "yaml error in query parameter -> error 400",
    req    => (GET "/?arg4b:j=%5B%22v4b%22"),
    spec   => $spec,
    status => 400,
);

test_getargs(
    name   => "php error in query parameter -> error 400",
    req    => (GET "/?arg4c:p=x%3A1%3A%7Bi%3A0%3Bs%3A3%3A%22v4c%22%3B%7D"),
    spec   => $spec,
    status => 400,
);

DONE_TESTING:
done_testing();

sub test_getargs {
    my %args = @_;

    subtest $args{name} => sub {
        test_psgi(
            app => sub {
                my $env = shift;
                my %ga_args = (psgi_env => $env, spec => $args{spec});
                for (qw/allow_unknown_params accept_json accept_yaml accept_php
                        per_var_encoding exclude_params/) {
                    $ga_args{$_} = $args{$_} if defined $args{$_};
                }
                my $res = get_args_from_getpost(%ga_args);
                [$res->[0], ['Content-Type' => 'text/yaml'], [Dump($res->[2])]];
            },
            client => sub {
                my $cb = shift;
                my $res = $cb->($args{req});
                is($res->code, $args{status} // 200, "status")
                    or diag explain $res;
                if ($res->code == 200) {
                    is($res->header('Content-Type'), 'text/yaml',
                       "Content-Type is yaml");
                    if ($args{res}) {
                        my $result = Load($res->content);
                        is_deeply($result, $args{res}, "result")
                            or diag explain $result;
                    }
                }
            },
        );
    };
}

