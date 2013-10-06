use MooseX::Declare;

role Net::AWS::V4Signature {
  use Net::Amazon::Signature::V4;
  #requires 'region';
  requires 'service';

  sub sign {
    my ($self, $request) = @_;
    my $sig = Net::Amazon::Signature::V4->new( $self->access_key, $self->secret_key, $self->region, $self->service );
    my $signed_req = $sig->sign( $request );
    return $signed_req;
  }
}

role Net::AWS::QueryCaller {
  method _is_internal_type ($att_type) {
    return ($att_type eq 'Str' or $att_type eq 'Int' or $att_type eq 'Bool' or $att_type eq 'Num');
  }
  method _to_params ($params) {
    my %p;
    foreach my $att (grep { $_ !~ m/^_/ } $params->meta->get_attribute_list) {
      if (defined $params->$att) {
        my $att_type = $params->meta->get_attribute($att)->type_constraint;
        if ($self->_is_internal_type($att_type)) {
          $p{ $att } = $params->{$att};
        } elsif ($att_type =~ m/^ArrayRef\[(.*)\]/) {
          if ($self->_is_internal_type("$1")){
            my $i = 1;
            foreach my $value (@{ $params->$att }){
              $p{ sprintf("%s.member.%d", $att, $i) } = $value;
              $i++
            }
          } else {
            my $i = 1;
            foreach my $value (@{ $params->$att }){
              $p{ sprintf("%s.member.%d", $att, $i) } = $value->_to_params($att);
              $i++
            }
          }
        } else {
          $p{ $att } = $params->$att->to_params($params->{$att});
        }
      }
    }
    use Data::Printer;
    p %p;
    return %p;
  }
  method _api_caller ($action, $params) {
    return $self->send(Action => $action, $self->_to_params($params));
  }
}

role Net::AWS::Caller {
  use POSIX qw(strftime);
  use Digest::SHA qw(hmac_sha256);
  use MIME::Base64 qw(encode_base64);
  use HTTP::Request::Common;
  use Carp qw(croak);
  use XML::Simple qw(XMLin);

  has 'access_key'         => ( is => 'rw', isa => 'Str', required => 1, lazy => 1, default => sub { $ENV{AWS_ACCESS_KEY} } );
  has 'secret_key'         => ( is => 'rw', isa => 'Str', required => 1, lazy => 1, default => sub { $ENV{AWS_SECRET_KEY} } );
  has 'debug'              => ( is => 'rw', required => 0, default => sub { 0 } );
  has 'version'            => ( is => 'rw', required => 1);
  has 'endpoint'           => ( is => 'rw', required => 1, lazy => 1, default => sub { $_[0]->_api_endpoint });
  has 'ua' => (is => 'rw', required => 1, lazy => 1,
    default     => sub {
        use HTTP::Tiny;
        HTTP::Tiny->new(
            'agent' => 'AWS Perl SDK 0.1',
        );
    }
  );

  sub _process {
    my $self = shift;
    my $data = shift;

    my $xml = XMLin( $data,
            ForceArray    => qr/(?:item|Errors)/i,
            KeyAttr       => '',
            SuppressEmpty => undef,
    );

    return $xml;
  }


  method send (%params){
    my $request = POST $self->endpoint . '/', Content => { %params };
    $request->header( Date => strftime( '%Y%m%dT%H%M%SZ', gmtime) );
    $request->header( Host => $self->endpoint_host );
    $request = $self->sign($request);
    my $headers = {};
    $request->scan(sub { $headers->{ $_[0] } = $_[1] });
    my $response = $self->ua->request(
      $request->method,
      $request->url,
      {
        headers => $headers,
        content => $request->content
      }
    );
    if ( $response->{success} ) {
        my $xml = $self->_process( $response->{content} );
        if ( defined $xml->{Errors} ) {
            croak "Error: $response->{content}\n";
        }
        return $xml;
    }

    croak "POST Request failed: $response->{status} $response->{reason} $response->{content}\n";
  }
}


