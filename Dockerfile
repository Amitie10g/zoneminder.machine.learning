ARG	BASEIMG=amitie10g/baseimage
ARG	BASEIMG_VERS=focal
ARG	PHP_VERS="7.4"
ARG	ZM_VERS="1.34"
FROM	$BASEIMG:$BASEIMG_VERS AS base

LABEL	maintainer="dlandon"

ARG	BASEIMG_VERS
ARG	PHP_VERS
ARG	ZM_VERS
ENV	DEBCONF_NONINTERACTIVE_SEEN="true" \
	DEBIAN_FRONTEND="noninteractive" \
	PYTHONPYCACHEPREFIX="/tmp/pip" \
	PATH="/opt/venv/bin:$PATH" \
	DISABLE_SSH="true" \
	HOME="/root" \
	LC_ALL="C.UTF-8" \
	LANG="en_US.UTF-8" \
	LANGUAGE="en_US.UTF-8" \
	TZ="Etc/UTC" \
	TERM="xterm" \
	PHP_VERS=$PHP_VERS \
	ZM_VERS=$ZM_VERS \
	PUID="99" \
	PGID="100"

FROM base AS step1
COPY init/ /etc/my_init.d/
COPY defaults/ /root/
COPY zmeventnotification/ /root/zmeventnotification/
COPY --from=amitie10g/zoneminder:models / /root/models

RUN	add-apt-repository -y ppa:iconnor/zoneminder-$ZM_VERS && \
	add-apt-repository ppa:ondrej/php && \
	add-apt-repository ppa:ondrej/apache2 && \
	apt-get update && \
	apt-get -y install apache2 mariadb-server && \
	apt-get -y install ssmtp mailutils net-tools wget sudo make cmake gcc && \
	apt-get -y install php$PHP_VERS php$PHP_VERS-fpm libapache2-mod-php$PHP_VERS php$PHP_VERS-mysql php$PHP_VERS-gd && \
	apt-get -y install libcrypt-mysql-perl libyaml-perl libjson-perl libavutil-dev ffmpeg && \
	apt-get -y install --no-install-recommends libvlc-dev libvlccore-dev vlc-bin vlc-plugin-base vlc-plugin-video-output && \
	apt-get -y install zoneminder

FROM step1 AS step2
RUN	rm /etc/mysql/my.cnf && \
	cp /etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/my.cnf && \
	adduser www-data video && \
	a2enmod php$PHP_VERS proxy_fcgi ssl rewrite expires headers && \
	a2enconf php$PHP_VERS-fpm zoneminder && \
	echo "extension=apcu.so" > /etc/php/$PHP_VERS/mods-available/apcu.ini && \
	echo "extension=mcrypt.so" > /etc/php/$PHP_VERS/mods-available/mcrypt.ini && \
	perl -MCPAN -e "force install Net::WebSocket::Server" && \
	perl -MCPAN -e "force install LWP::Protocol::https" && \
	perl -MCPAN -e "force install Config::IniFiles" && \
	perl -MCPAN -e "force install Net::MQTT::Simple" && \
	perl -MCPAN -e "force install Net::MQTT::Simple::Auth" && \
	perl -MCPAN -e "force install Time::Piece"

FROM step2 AS step3
RUN apt-get -y install libopenblas-dev liblapack-dev libblas-dev libgeos-dev python3-pip python3-setuptools python3-shapely python3-future && \
	pip3 install /root/zmeventnotification && \
	pip3 install face_recognition && \
	rm -r /root/zmeventnotification/zmes_hook_helpers

FROM step3 AS step4
RUN	cd /root && \
	chown -R www-data:www-data /usr/share/zoneminder/ && \
	echo "ServerName localhost" >> /etc/apache2/apache2.conf && \
	sed -i "s|^;date.timezone =.*|date.timezone = ${TZ}|" /etc/php/$PHP_VERS/apache2/php.ini && \
	service mysql start && \
	mysql -uroot < /usr/share/zoneminder/db/zm_create.sql && \
	mysql -uroot -e "grant all on zm.* to 'zmuser'@localhost identified by 'zmpass';" && \
	mysqladmin -uroot reload && \
	mysql -sfu root < "mysql_secure_installation.sql" && \
	rm mysql_secure_installation.sql && \
	mysql -sfu root < "mysql_defaults.sql" && \
	rm mysql_defaults.sql

FROM step4 AS step5
RUN	mv /root/zoneminder /etc/init.d/zoneminder && \
	chmod +x /etc/init.d/zoneminder && \
	service mysql restart && \
	sleep 5 && \
	service apache2 start && \
	service zoneminder start

FROM step5 AS step6
RUN	systemd-tmpfiles --create zoneminder.conf && \
	mv /root/default-ssl.conf /etc/apache2/sites-enabled/default-ssl.conf && \
	mkdir /etc/apache2/ssl/ && \
	mkdir -p /var/lib/zmeventnotification/images && \
	chown -R www-data:www-data /var/lib/zmeventnotification/ && \
	chmod -R +x /etc/my_init.d/ && \
	cp -p /etc/zm/zm.conf /root/zm.conf && \
	echo "#!/bin/sh\n\n/usr/bin/zmaudit.pl -f" >> /etc/cron.weekly/zmaudit && \
	chmod +x /etc/cron.weekly/zmaudit && \
	cp /etc/apache2/ports.conf /etc/apache2/ports.conf.default && \
	cp /etc/apache2/sites-enabled/default-ssl.conf /etc/apache2/sites-enabled/default-ssl.conf.default && \
	sed -i s#3.13#3.25#g /etc/syslog-ng/syslog-ng.conf && \
	sed -i 's#use_dns(no)#use_dns(yes)#' /etc/syslog-ng/syslog-ng.conf

FROM step6 AS step7
RUN	cd /root && \
	wget -q -O opencv.zip https://github.com/opencv/opencv/archive/4.5.1.zip && \
	wget -q -O opencv_contrib.zip https://github.com/opencv/opencv_contrib/archive/4.5.1.zip && \
	unzip opencv.zip && \
	unzip opencv_contrib.zip && \
	mv $(ls -d opencv-*) opencv && \
	mv opencv_contrib-4.5.1 opencv_contrib && \
	rm *.zip && \
	cd /root/opencv && \
	mkdir build && \
	cd build && \
	cmake -D CMAKE_BUILD_TYPE=RELEASE -D CMAKE_INSTALL_PREFIX=/usr/local -D INSTALL_PYTHON_EXAMPLES=OFF -D INSTALL_C_EXAMPLES=OFF -D OPENCV_ENABLE_NONFREE=ON -D OPENCV_EXTRA_MODULES_PATH=/root/opencv_contrib/modules -D HAVE_opencv_python3=ON -D PYTHON_EXECUTABLE=/usr/bin/python3 -D PYTHON2_EXECUTABLE=/usr/bin/python2 -D BUILD_EXAMPLES=OFF .. >/dev/null && \
	make -j4 && \
	make install && \
	cd /root && \
	rm -r opencv*

FROM step7 AS step8
RUN	apt-get -y clean && \
	apt-get -y autoremove && \
	rm -rf /tmp/* /var/tmp/* /root/.cache /root/.cpan && \
	chmod +x /etc/my_init.d/*.sh

FROM step8 AS step9
VOLUME \
	["/config"] \
	["/var/cache/zoneminder"]

FROM step9 AS step10
EXPOSE 80 443 9000

FROM step10
WORKDIR /root
CMD ["/sbin/my_init"]
