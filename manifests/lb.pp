define hydra::lb (
  $app_name,
  $parent_interface,
  $subnet_mask = '255.255.255.0',
  $box_a_sub_ip,
  $box_b_sub_ip,
  $ports = ['80:80', '443:443'],
  $vip_ip,
  $vip_id,
  $vip_password,
  $ucarp_options = '--advskew 1 --advbase 1 --preempt --neutral',
  $consul_args = hiera('consul::args'),
  $lb_engine = 'nginx',
  $lb_config_repo = undef,
  $lb_config_branch = undef,
  $lb_config_identity = undef,
  $lb_container = 'nginx/nginx:latest',
  $lb_config_file = '/etc/nginx/nginx.conf',
) {

  case hiera('hydra::box_id', 'unknown') {
    /^[aA]$/: {
      $source_address = $box_a_sub_ip
    }
    /^[bB]$/: {
      $source_address = $box_b_sub_ip
    }
    default: {
      fail("missing or invalid hydra::box_id, valid values are a or b")
    }
  }


  #FIXME add a require on the sub interface
  ucarp::vip { $app_name:
    id             => $vip_id,
    bind_interface => "${parent_interface}:${app_name}",
    vip_address    => $vip_ip,
    source_address => $source_address,
    password       => $vip_password,
    options        => $ucarp_options,
    require        => Network::Alias["${parent_interface}:${app_name}"]
  }


  #FIXME make sure networkmanager isn't involved in kickstarted boxes
  network::alias { "${parent_interface}:${app_name}":
    ensure    => 'up',
    ipaddress => $source_address,
    netmask   => $subnet_mask,
    notify    => Exec["${parent_interface}:${app_name} ifup"],
    #require   => Service['NetworkManager']
  }

  exec{ "${parent_interface}:${app_name} ifup":
    path        => "/usr/sbin",
    command     => "/usr/sbin/ifup ${parent_interface}:${app_name}",
    refreshonly => true,
    require     => Network::Alias["${parent_interface}:${app_name}"]
  }

  case $lb_engine {
    'nginx': {
      $lb_reload_cmd = '/usr/local/sbin/nginx_reload'
    }
    default: {
      fail('unsupported load balancing engine')
    }
  }

  $docker_ports = prefix($ports, "${source_address}:")

  if $lb_config_repo {
    unless $lb_config_branch {
      fail('if you specify a repo, you must also specify the branch (lb_config_branch)')
    } 

    unless defined(File['/docker']) {
      file { '/docker':
        ensure => 'directory'
      }
    }
  
    unless defined(File['/docker/hydra']) {
      file {'/docker/hydra':
        ensure => 'directory',
        require => File['/docker']
      }
    }

    file {"/docker/hydra/${app_name}":
      ensure => 'directory',
      require => File['/docker/hydra']
    }

    vcsrepo { "/docker/hydra/${app_name}":
      ensure => latest,
      provider => 'git',
      source =>  $lb_config_repo,
      revision => $lb_config_branch,
      identity => $lb_config_identity,
      require => File["/docker/hydra/${app_name}"]
    }


    docker::run {"${app_name}-lb":
      image => $lb_container,
      ports   => $docker_ports,
      volumes => ["/docker/hydra/${app_name}:/etc/lbconfig"],
      env     => [ "\'CONSUL_TEMPLATE_ARGS=${nginx_consul_template_args} -template /etc/lbconfig/nginx.tmpl:/etc/nginx/nginx.conf:${lb_reload_cmd}\'"],
    }
  } else {
    docker::run {"${app_name}-lb":
      image => $lb_container,
      ports   => $docker_ports,
      env     => [ "\'APPNAME=${app_name}\'", "\'CONSUL_TEMPLATE_ARGS=${consul_args} -template /etc/consul-templates/nginx.conf:/etc/nginx/nginx.conf:${lb_reload_cmd}\'" ],
    }
  }

  unless defined(Service['firewalld']) {
    service {'firewalld': 
      enable => false
    }
  }

  unless defined(Package['iptables-services']) {
    package{ 'iptables-services':
      ensure => present
    }
  }

  unless defined(Package['iptables']) {
    service{ 'iptables':
      enable      => true,
      ensure      => 'running',
      require     => Package['iptables-services'],
      notify      => Exec["flush iptables"],
    }

    case $::osfamily {
      redhat: {
        exec{ "flush iptables":
          path        => "/usr/sbin",
          command     => "/usr/sbin/iptables -F ; /usr/sbin/iptables -t nat -F",
          refreshonly => true,
          notify      => Exec['save iptables'],
        }
        exec{ "save iptables":
          path        => "/usr/sbin",
          command     => "/usr/sbin/iptables-save > /etc/sysconfig/iptables ; /usr/sbin/iptables-save > /etc/sysconfig/iptables.save",
          refreshonly => true,
          notify      => Service['docker'],
        }
      }
      default: {
        fail("Unsupported platform: ${::osfamily}/${::operatingsystem}")
      }
    }

  }

####  unless defined(Service['NetworkManager']) {
####    service{ 'NetworkManager':
####      enable => false,
####      ensure => 'stopped'
####    }
####  }

  firewall { "001 ${app_name} vip nat":
    chain       => 'PREROUTING',
    jump        => 'DNAT',
    proto       => 'all',
    #outiface    => $parent_interface,
    table       => 'nat',
    destination => $vip_ip,
    todest      => $source_address,
    require     => Service['iptables']
  }

  firewall { "002 ${app_name} vip nat":
    chain       => 'POSTROUTING',
    jump        => 'SNAT',
    proto       => 'all',
    #outiface    => $parent_interface,
    table       => 'nat',
    destination => $source_address,
    tosource    => $vip_ip,
    require     => Service['iptables']
  }

  firewall { "003 ${app_name} vip nat":
    chain       => 'OUTPUT',
    jump        => 'DNAT',
    proto       => 'all',
    #outiface    => $parent_interface,
    table       => 'nat',
    destination => $vip_ip,
    todest      => $source_address,
    require     => Service['iptables']
  }

}

