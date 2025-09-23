vf_sources = [
    'vf_driver.m',
    'vf_conf.m',
    'vf_machine.m',
    'vf_domain.m',
]

if conf.has('WITH_VF')
    virt_dep = dependency('appleframeworks', modules: 'Virtualization')
  
    vf_driver_impl = static_library(
        'virt_driver_vf_impl',
        [
            vf_sources,
        ],
        dependencies: [
            src_dep,
            virt_dep,
            access_dep,
        ],
        include_directories: [
            conf_inc_dir,
            hypervisor_inc_dir,
        ],
        objc_args: [
          '-fobjc-arc',
        ]
    )

    virt_modules += {
    'name': 'virt_driver_vf',
    'link_whole': [
      vf_driver_impl,
    ],
    'link_args': [
      libvirt_no_undefined,
    ],
  }
endif