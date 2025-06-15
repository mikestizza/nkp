# KuberEats 🍕

A cloud-native food delivery demo application built for Kubernetes.

## 🎯 Overview

KuberEats is a microservices-based food delivery application designed to demonstrate Kubernetes deployment patterns, container orchestration, and cloud-native best practices. Perfect for demos, workshops, and learning Kubernetes concepts.

## 🏗️ Architecture

The application consists of three main components:

- **Frontend** - React-based web UI served by Nginx
- **Backend API** - Node.js Express REST API
- **Database** - PostgreSQL for persistent storage

```
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│   Frontend  │────▶│ Backend API │────▶│  PostgreSQL  │
│   (Nginx)   │     │  (Node.js)  │     │   Database   │
└─────────────┘     └─────────────┘     └──────────────┘
```

## ✨ Features

- Browse restaurants and menus
- Add items to cart
- Session-based cart management
- Responsive web interface
- RESTful API design
- Persistent data storage
- Health checks and readiness probes
- Horizontal pod autoscaling ready

## 🚀 Quick Start

### Prerequisites

- Kubernetes cluster (1.19+)
- kubectl configured
- Storage class available (for PostgreSQL PVC)

### Deploy to Kubernetes

1. **Create namespace**
   ```bash
   kubectl create namespace kubereats
   ```

2. **Deploy all components**
   ```bash
   kubectl apply -f postgres-deployment.yaml
   kubectl apply -f backend-api.yaml
   kubectl apply -f frontend-app.yaml
   ```

3. **Check deployment status**
   ```bash
   kubectl get all -n kubereats
   ```

4. **Access the application**
   ```bash
   kubectl get svc -n kubereats frontend
   ```
   
   Use the LoadBalancer IP or set up port forwarding:
   ```bash
   kubectl port-forward -n kubereats svc/frontend 8080:80
   ```
   
   Then open http://localhost:8080 in your browser.

## 🔧 Configuration

### Environment Variables

The backend API supports the following environment variables:
- `DB_HOST` - PostgreSQL host (default: postgres)
- `DB_PORT` - PostgreSQL port (default: 5432)
- `DB_USER` - Database user
- `DB_PASSWORD` - Database password
- `DB_NAME` - Database name

### Storage

PostgreSQL uses a PersistentVolumeClaim. Modify the storage class in `postgres-deployment.yaml` to match your cluster:
```yaml
storageClassName: your-storage-class
```

## 📊 Monitoring

Each component includes health checks:

- **Frontend**: `/health`
- **Backend**: `/health`
- **Database**: PostgreSQL readiness probe

## 🛠️ Development

### Local Development

For local development without Kubernetes:

1. Run PostgreSQL locally or in Docker
2. Set environment variables
3. Install dependencies and run the backend
4. Serve the frontend with any web server

### Customization

- Modify the sample data in `postgres-deployment.yaml`
- Update the UI in the frontend ConfigMap
- Add new API endpoints in the backend deployment

## 📦 Components Detail

### Frontend
- Single-page application
- Pure JavaScript (no build process required)
- Nginx web server
- Responsive design

### Backend API
- RESTful endpoints
- PostgreSQL connection pooling
- CORS enabled
- Error handling

### Database
- PostgreSQL 15
- Initialization script included
- Sample data preloaded
- Backup CronJob (optional)

## 🤝 Contributing

This is a demo application intended for learning and demonstration purposes. Feel free to fork and modify for your own use cases.

## ⚠️ Production Considerations

This demo app is NOT production-ready. For production use, consider:
- Implementing proper authentication/authorization
- Adding SSL/TLS termination
- Implementing rate limiting
- Adding comprehensive logging and monitoring
- Implementing proper backup strategies
- Adding input validation and sanitization
- Implementing proper secret management

## 📄 License

This demo application is open source and available under the MIT License.

## 🙏 Acknowledgments

Built as a demonstration of Kubernetes capabilities and cloud-native application design patterns.

---

**Note**: This is a demo application for educational purposes. Not intended for production use.