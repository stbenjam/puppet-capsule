# == Class: capsule
#
# Configure a Katello capsule
#
# === Parameters:
#
# $parent_fqdn::                        FQDN of the parent node.
#
# $enable_ostree::                      Boolean to enable ostree plugin. This requires existence of an ostree install.
#                                       type:boolean
#
# $certs_tar::                          Path to a tar with certs for the node
#
# === Advanced parameters:
#
# $pulp_master::                        Whether the capsule should be identified as a pulp master server
#                                       type:boolean
#
# $pulp_admin_password::                Password for the Pulp admin user. It should be left blank so that a random password is generated
#
# $pulp_oauth_effective_user::          User to be used for Pulp REST interaction
#
# $pulp_oauth_key::                     OAuth key to be used for Pulp REST interaction
#
# $pulp_oauth_secret::                  OAuth secret to be used for Pulp REST interaction
#
# $reverse_proxy::                      Add reverse proxy to the parent
#                                       type:boolean
#
# $reverse_proxy_port::                 Reverse proxy listening port
#
# $rhsm_url::                           The URL that the RHSM API is rooted at
#
# $qpid_router::                        Configure qpid dispatch router
#                                       type:boolean
#
# $qpid_router_hub_addr::               Address for dispatch router hub
#
# $qpid_router_hub_port::               Port for dispatch router hub
#
# $qpid_router_agent_addr::             Listener address for goferd agents
#
# $qpid_router_agent_port::             Listener port for goferd agents
#
# $qpid_router_broker_addr::            Address of qpidd broker to connect to
#
# $qpid_router_broker_port::            Port of qpidd broker to connect to
#
# $qpid_router_logging_level::          Logging level of dispatch router (e.g. info+ or debug+)
#
# $qpid_router_logging_path::           Directory for dispatch router logs
#
class capsule (
  $parent_fqdn                  = $capsule::params::parent_fqdn,
  $certs_tar                    = $capsule::params::certs_tar,
  $pulp_master                  = $capsule::params::pulp_master,
  $pulp_admin_password          = $capsule::params::pulp_admin_password,
  $pulp_oauth_effective_user    = $capsule::params::pulp_oauth_effective_user,
  $pulp_oauth_key               = $capsule::params::pulp_oauth_key,
  $pulp_oauth_secret            = $capsule::params::pulp_oauth_secret,

  $reverse_proxy                = $capsule::params::reverse_proxy,
  $reverse_proxy_port           = $capsule::params::reverse_proxy_port,

  $rhsm_url                     = $capsule::params::rhsm_url,

  $qpid_router                  = $capsule::params::qpid_router,
  $qpid_router_hub_addr         = $capsule::params::qpid_router_hub_addr,
  $qpid_router_hub_port         = $capsule::params::qpid_router_hub_port,
  $qpid_router_agent_addr       = $capsule::params::qpid_router_agent_addr,
  $qpid_router_agent_port       = $capsule::params::qpid_router_agent_port,
  $qpid_router_broker_addr      = $capsule::params::qpid_router_broker_addr,
  $qpid_router_broker_port      = $capsule::params::qpid_router_broker_port,
  $qpid_router_logging_level    = $capsule::params::qpid_router_logging_level,
  $qpid_router_logging_path     = $capsule::params::qpid_router_logging_path,
  $enable_ostree                = $capsule::params::enable_ostree,
) inherits capsule::params {
  validate_bool($enable_ostree)

  include ::certs
  include ::foreman_proxy
  include ::foreman_proxy::plugin::pulp

  validate_present($capsule::parent_fqdn)
  validate_absolute_path($capsule::qpid_router_logging_path)

  $pulp = $::foreman_proxy::plugin::pulp::pulpnode_enabled
  if $pulp {
    validate_present($pulp_oauth_secret)
  }

  $capsule_fqdn = $::fqdn
  $foreman_url = "https://${parent_fqdn}"
  $reverse_proxy_real = $pulp or $reverse_proxy

  $rhsm_port = $reverse_proxy_real ? {
    true  => $reverse_proxy_port,
    false => '443'
  }

  package{ ['katello-debug', 'katello-client-bootstrap']:
    ensure => installed,
  }

  class { '::certs::foreman_proxy':
    hostname => $capsule_fqdn,
    require  => Package['foreman-proxy'],
    before   => Service['foreman-proxy'],
  } ~>
  class { '::certs::katello':
    deployment_url => $capsule::rhsm_url,
    rhsm_port      => $capsule::rhsm_port,
  }

  if $pulp or $reverse_proxy_real {
    class { '::certs::apache':
      hostname => $capsule_fqdn,
    } ~>
    Class['certs::foreman_proxy'] ~>
    class { '::capsule::reverse_proxy':
      path => '/',
      url  => "${foreman_url}/",
      port => $capsule::reverse_proxy_port,
    }
  }

  if $pulp_master or $pulp {
    if $qpid_router {
      class { '::capsule::dispatch_router':
        require => Class['pulp'],
      }
    }
  }

  if $pulp {
    include ::apache
    $apache_version = $::apache::apache_version

    file {'/etc/httpd/conf.d/pulp_nodes.conf':
      ensure  => file,
      content => template('capsule/pulp_nodes.conf.erb'),
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
    }

    apache::vhost { 'capsule':
      servername      => $capsule_fqdn,
      port            => 80,
      priority        => '05',
      docroot         => '/var/www/html',
      options         => ['SymLinksIfOwnerMatch'],
      custom_fragment => template('capsule/_pulp_includes.erb', 'capsule/httpd_pub.erb'),
    }

    class { '::certs::qpid': } ~>
    class { '::certs::qpid_client': } ~>
    class { '::qpid':
      ssl                    => true,
      ssl_cert_db            => $::certs::nss_db_dir,
      ssl_cert_password_file => $::certs::qpid::nss_db_password_file,
      ssl_cert_name          => 'broker',
    } ~>
    class { '::pulp':
      enable_crane              => true,
      enable_rpm                => true,
      enable_puppet             => true,
      enable_docker             => true,
      enable_ostree             => $enable_ostree,
      default_password          => $pulp_admin_password,
      oauth_enabled             => true,
      oauth_key                 => $pulp_oauth_key,
      oauth_secret              => $pulp_oauth_secret,
      messaging_transport       => 'qpid',
      messaging_auth_enabled    => false,
      messaging_ca_cert         => $certs::ca_cert,
      messaging_client_cert     => $certs::params::messaging_client_cert,
      messaging_url             => "ssl://${capsule_fqdn}:5671",
      broker_url                => "qpid://${qpid_router_broker_addr}:${qpid_router_broker_port}",
      broker_use_ssl            => true,
      manage_broker             => false,
      manage_httpd              => true,
      manage_plugins_httpd      => true,
      manage_squid              => true,
      repo_auth                 => true,
      node_oauth_effective_user => $pulp_oauth_effective_user,
      node_oauth_key            => $pulp_oauth_key,
      node_oauth_secret         => $pulp_oauth_secret,
      node_server_ca_cert       => $certs::params::pulp_server_ca_cert,
      https_cert                => $certs::apache::apache_cert,
      https_key                 => $certs::apache::apache_key,
      ca_cert                   => $certs::ca_cert,
    }

    pulp::apache::fragment{'gpg_key_proxy':
      ssl_content => template('capsule/_pulp_gpg_proxy.erb'),
    }
  }

  if $certs_tar {
    certs::tar_extract { $capsule::certs_tar: } -> Class['certs']
    Certs::Tar_extract[$certs_tar] -> Class['certs::foreman_proxy']

    if $reverse_proxy_real or $pulp {
      Certs::Tar_extract[$certs_tar] -> Class['certs::apache']
    }

    if $pulp {
      Certs::Tar_extract[$certs_tar] -> Class['certs'] -> Class['::certs::qpid']
    }
  }
}
