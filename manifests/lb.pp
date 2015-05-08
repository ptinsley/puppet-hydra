define hydra::lb (
  $app_name,
  $parent_interface,
  $subnet_mask = '255.255.255.0',
  $box_a_sub_ip,
  $box_b_sub_ip,
  $ports = ['80', '443'],
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
    options        => $ucarp_options
  }

  network::if::static { "${parent_interface}:${app_name}":
    ensure    => 'up',
    ipaddress => $source_address,
    netmask   => $subnet_mask
  }

  case $lb_engine {
    'nginx': {
      $lb_reload_cmd = '/usr/local/sbin/nginx_reload'
    }
    default: {
      fail('unsupported load balancing engine')
    }
  }

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
      ports   => $ports,
      volumes => ["/docker/hydra/${app_name}:/etc/lbconfig"],
      env     => [ "\'CONSUL_TEMPLATE_ARGS=${nginx_consul_template_args} -template /etc/lbconfig/nginx.tmpl:/etc/nginx/nginx.conf:${lb_reload_cmd}\'" 
],
    }
  } else {
    docker::run {"${app_name}-lb":
      image => $lb_container,
      ports   => $ports,
      env     => [ "\'APPNAME=${app_name}\'", "\'CONSUL_TEMPLATE_ARGS=${consul_args} -template /etc/consul-templates/nginx.conf:/etc/nginx/nginx.conf:${lb_reload_cmd}\'" ],
    }
  }
}

