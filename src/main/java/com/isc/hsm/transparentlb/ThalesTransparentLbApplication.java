package com.isc.hsm.transparentlb;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
public class ThalesTransparentLbApplication {
    public static void main(String[] args) {
        SpringApplication.run(ThalesTransparentLbApplication.class, args);
    }
}
