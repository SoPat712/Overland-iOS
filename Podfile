# Uncomment this line to define a global platform for your project

platform :ios, '17.0'

target 'Overland' do
	pod 'AFNetworking', '4.0.1'
	pod 'FMDB', '2.7.5'

	post_install do |installer|
		# AFNetworking 4.0.1 includes netinet6/in6.h directly, which new SDKs
		# reject as a private-module header. netinet/in.h is the public route.
		af_reachability = File.join(installer.sandbox.root, 'AFNetworking', 'AFNetworking', 'AFNetworkReachabilityManager.m')
		if File.exist?(af_reachability)
			['AFNetworkReachabilityManager.m', 'AFHTTPSessionManager.m'].each do |name|
				path = File.join(installer.sandbox.root, 'AFNetworking', 'AFNetworking', name)
				next unless File.exist?(path)
				content = File.read(path)
				patched = content.gsub('#import <netinet6/in6.h>', '#import <netinet/in.h>')
				if content != patched
					File.chmod(0644, path)
					File.write(path, patched)
				end
			end
		end
		installer.pods_project.targets.each do |target|
			target.build_configurations.each do |config|
				config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
			end
		end
	end
end

